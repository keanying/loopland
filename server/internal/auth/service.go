package auth

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"

	"github.com/keanying/loopland/server/internal/gameplay"
	"github.com/keanying/loopland/server/internal/nickname"
	"github.com/keanying/loopland/server/internal/platform/db"
	"github.com/keanying/loopland/server/internal/platform/httpx"
	"github.com/keanying/loopland/server/internal/platform/secure"
	"github.com/keanying/loopland/server/internal/user"
)

// Service implements login, binding and tokens.
type Service struct {
	Pool    *pgxpool.Pool
	Redis   *redis.Client
	Box     *secure.Box
	Config  *gameplay.Store
	SMS     SMSSender
	OneTap  OneClick
	WeChat  WeChat
	Apple   Apple
	Captcha Captcha

	JWTSecret  []byte
	AccessTTL  time.Duration
	RefreshTTL time.Duration
	// DevCode, when set, is accepted for any phone (dev only).
	DevCode string
}

var phoneRe = regexp.MustCompile(`^1[3-9]\d{9}$`)

// SMS limits (docs/api/v1.md).
const (
	smsCooldown   = 60 * time.Second
	smsPerDay     = 10
	smsPerIPHour  = 30
	smsCodeTTL    = 5 * time.Minute
	smsMaxAttempt = 5
)

var (
	errInvalidPhone = httpx.BadRequest("invalid_phone", "手机号格式不正确")
	errInvalidCode  = httpx.BadRequest("invalid_code", "验证码错误")
	errCodeExpired  = httpx.BadRequest("code_expired", "验证码已过期，请重新获取")
)

// SendCode issues an SMS code with rate limits.
func (s *Service) SendCode(ctx context.Context, phone, captcha, ip string) error {
	if !phoneRe.MatchString(phone) {
		return errInvalidPhone
	}
	if err := s.Captcha.Verify(ctx, captcha, ip); err != nil {
		return httpx.BadRequest("captcha_failed", "人机验证未通过")
	}
	ok, err := s.Redis.SetNX(ctx, "sms:cd:"+phone, 1, smsCooldown).Result()
	if err != nil {
		return err
	}
	if !ok {
		return httpx.ErrRateLimited
	}
	day := time.Now().Format("20060102")
	if n, err := incr(ctx, s.Redis, "sms:day:"+phone+":"+day, 24*time.Hour); err != nil || n > smsPerDay {
		return limitErr(err)
	}
	hour := time.Now().Format("2006010215")
	if n, err := incr(ctx, s.Redis, "sms:ip:"+ip+":"+hour, time.Hour); err != nil || n > smsPerIPHour {
		return limitErr(err)
	}
	n, _ := rand.Int(rand.Reader, big.NewInt(1_000_000))
	code := fmt.Sprintf("%06d", n.Int64())
	pipe := s.Redis.TxPipeline()
	pipe.Set(ctx, "sms:code:"+phone, secure.Hash(code), smsCodeTTL)
	pipe.Del(ctx, "sms:try:"+phone)
	if _, err := pipe.Exec(ctx); err != nil {
		return err
	}
	if err := s.SMS.Send(ctx, phone, code); err != nil {
		s.Redis.Del(ctx, "sms:cd:"+phone)
		return httpx.E(http.StatusBadGateway, "provider_error", "短信发送失败，请稍后再试")
	}
	return nil
}

func limitErr(err error) error {
	if err != nil {
		return err
	}
	return httpx.ErrRateLimited
}

func incr(ctx context.Context, r *redis.Client, key string, ttl time.Duration) (int64, error) {
	pipe := r.TxPipeline()
	n := pipe.Incr(ctx, key)
	pipe.Expire(ctx, key, ttl)
	_, err := pipe.Exec(ctx)
	return n.Val(), err
}

// CheckCode verifies (and consumes) an SMS code.
func (s *Service) CheckCode(ctx context.Context, phone, code string) error {
	if !phoneRe.MatchString(phone) {
		return errInvalidPhone
	}
	if s.DevCode != "" && code == s.DevCode {
		return nil
	}
	n, err := incr(ctx, s.Redis, "sms:try:"+phone, smsCodeTTL)
	if err != nil {
		return err
	}
	stored, err := s.Redis.Get(ctx, "sms:code:"+phone).Bytes()
	if errors.Is(err, redis.Nil) {
		return errCodeExpired
	}
	if err != nil {
		return err
	}
	if n > smsMaxAttempt {
		s.Redis.Del(ctx, "sms:code:"+phone)
		return errCodeExpired
	}
	if subtle.ConstantTimeCompare(stored, secure.Hash(code)) != 1 {
		return errInvalidCode
	}
	s.Redis.Del(ctx, "sms:code:"+phone, "sms:try:"+phone)
	return nil
}

// Result is the login response.
type Result struct {
	AccessToken   string    `json:"access_token"`
	RefreshToken  string    `json:"refresh_token"`
	ExpiresIn     int       `json:"expires_in"`
	IsNew         bool      `json:"is_new"`
	NeedBindPhone bool      `json:"need_bind_phone"`
	User          user.User `json:"user"`
}

// LoginRequest is POST /v1/auth/login.
type LoginRequest struct {
	Provider   string            `json:"provider"`
	Credential map[string]string `json:"credential"`
	DeviceID   string            `json:"device_id"`
	Platform   string            `json:"platform"`
}

func providerErr(err error) error {
	if errors.Is(err, ErrProvider) {
		return httpx.E(http.StatusBadRequest, "provider_error", "登录失败，请重试")
	}
	return err
}

// Login resolves the credential to an account (creating it if needed).
func (s *Service) Login(ctx context.Context, req LoginRequest) (Result, error) {
	var uid int64
	var isNew bool
	var err error
	switch req.Provider {
	case "sms":
		phone := req.Credential["phone"]
		if err := s.CheckCode(ctx, phone, req.Credential["code"]); err != nil {
			return Result{}, err
		}
		uid, isNew, err = s.byPhone(ctx, phone, "sms")
	case "oneclick":
		phone, perr := s.OneTap.Mobile(ctx, req.Credential["token"])
		if perr != nil {
			return Result{}, providerErr(perr)
		}
		uid, isNew, err = s.byPhone(ctx, phone, "oneclick")
	case "wechat":
		id, perr := s.WeChat.Exchange(ctx, req.Credential["code"])
		if perr != nil {
			return Result{}, providerErr(perr)
		}
		nick := id.Nickname
		if nick == "" {
			nick = "微信用户"
		}
		uid, isNew, err = s.byIdentity(ctx, "wechat", id.OpenID, id.UnionID, nick, id.Avatar)
	case "apple":
		sub, perr := s.Apple.Verify(ctx, req.Credential["identity_token"])
		if perr != nil {
			return Result{}, providerErr(perr)
		}
		uid, isNew, err = s.byIdentity(ctx, "apple", sub, "", req.Credential["nickname"], "")
	default:
		return Result{}, httpx.BadRequest("invalid_body", "不支持的登录方式")
	}
	if err != nil {
		return Result{}, err
	}
	if err := s.checkStatus(ctx, uid); err != nil {
		return Result{}, err
	}
	if _, err := s.Pool.Exec(ctx, `UPDATE src.src_usr_loop_user SET last_login_time=now() WHERE id=$1`, uid); err != nil {
		return Result{}, err
	}
	if req.DeviceID != "" {
		if _, err := s.Pool.Exec(ctx, `INSERT INTO src.src_usr_loop_device (device_id, user_id) VALUES ($1,$2)
			ON CONFLICT (device_id, user_id) DO UPDATE SET last_seen_time=now()`, req.DeviceID, uid); err != nil {
			return Result{}, err
		}
	}
	res, err := s.issue(ctx, uid, uuid.New(), req.DeviceID)
	res.IsNew = isNew
	return res, err
}

func (s *Service) checkStatus(ctx context.Context, uid int64) error {
	var status string
	var until *time.Time
	if err := s.Pool.QueryRow(ctx, `SELECT status, ban_end_time FROM src.src_usr_loop_user WHERE id=$1`, uid).Scan(&status, &until); err != nil {
		return err
	}
	if status == "banned" {
		if until != nil && until.Before(time.Now()) {
			_, err := s.Pool.Exec(ctx, `UPDATE src.src_usr_loop_user SET status='active', ban_end_time=NULL WHERE id=$1`, uid)
			return err
		}
		e := httpx.Forbidden("account_banned", "账号已被封禁")
		if until != nil {
			e.Extra = map[string]any{"banned_until": until}
		}
		return e
	}
	if status == "deleted" {
		return httpx.ErrUnauthorized
	}
	return nil
}

// randomNick is the default nickname at registration: 「圈圈」+ a sports
// description (e.g. 圈圈晨跑侠).
func randomNick() string { return nickname.Random() }

func (s *Service) byPhone(ctx context.Context, phone, source string) (int64, bool, error) {
	if !phoneRe.MatchString(phone) {
		return 0, false, errInvalidPhone
	}
	h := s.Box.Lookup(phone)
	var id int64
	err := s.Pool.QueryRow(ctx, `SELECT id FROM src.src_usr_loop_user WHERE phone_hash=$1`, h).Scan(&id)
	if err == nil {
		return id, false, nil
	}
	if !db.IsNoRows(err) {
		return 0, false, err
	}
	err = s.Pool.QueryRow(ctx, `INSERT INTO src.src_usr_loop_user (phone_enc, phone_hash, phone_last4, nickname, source) VALUES ($1,$2,$3,$4,$5)
		ON CONFLICT (phone_hash) DO NOTHING RETURNING id`, s.Box.Seal(phone), h, phone[7:], randomNick(), source).Scan(&id)
	if db.IsNoRows(err) { // concurrent first login
		err = s.Pool.QueryRow(ctx, `SELECT id FROM src.src_usr_loop_user WHERE phone_hash=$1`, h).Scan(&id)
		return id, false, err
	}
	return id, true, err
}

func (s *Service) byIdentity(ctx context.Context, provider, uid, union, nick, avatar string) (int64, bool, error) {
	var id int64
	err := s.Pool.QueryRow(ctx, `SELECT user_id FROM src.src_usr_loop_identity WHERE provider=$1 AND provider_uid=$2`, provider, uid).Scan(&id)
	if err == nil {
		return id, false, nil
	}
	if !db.IsNoRows(err) {
		return 0, false, err
	}
	if union != "" {
		err := s.Pool.QueryRow(ctx, `SELECT user_id FROM src.src_usr_loop_identity WHERE provider=$1 AND union_id=$2`, provider, union).Scan(&id)
		if err == nil {
			_, err = s.Pool.Exec(ctx, `INSERT INTO src.src_usr_loop_identity (user_id, provider, provider_uid, union_id) VALUES ($1,$2,$3,NULL) ON CONFLICT DO NOTHING`, id, provider, uid)
			return id, false, err
		}
		if !db.IsNoRows(err) {
			return 0, false, err
		}
	}
	if nick == "" {
		nick = randomNick()
	}
	err = pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		if err := tx.QueryRow(ctx, `INSERT INTO src.src_usr_loop_user (nickname, avatar_url, source) VALUES ($1, NULLIF($2,''), $3) RETURNING id`, nick, avatar, provider).Scan(&id); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `INSERT INTO src.src_usr_loop_identity (user_id, provider, provider_uid, union_id) VALUES ($1,$2,$3,NULLIF($4,''))`, id, provider, uid, union)
		return err
	})
	if db.IsUniqueViolation(err) {
		return s.byIdentity(ctx, provider, uid, union, nick, avatar)
	}
	return id, err == nil, err
}

// BindPhone attaches a phone to a WeChat/Apple account. If the phone already
// belongs to another account, the third-party identity is moved onto that
// account instead only when that account has no identity for the same
// provider; otherwise it is a conflict.
func (s *Service) BindPhone(ctx context.Context, uid int64, phone string) error {
	h := s.Box.Lookup(phone)
	var other int64
	err := s.Pool.QueryRow(ctx, `SELECT id FROM src.src_usr_loop_user WHERE phone_hash=$1`, h).Scan(&other)
	if err == nil && other != uid {
		return httpx.Conflict("phone_taken", "这个手机号已经绑定了其他账号")
	}
	if err != nil && !db.IsNoRows(err) {
		return err
	}
	_, err = s.Pool.Exec(ctx, `UPDATE src.src_usr_loop_user SET phone_enc=$2, phone_hash=$3, phone_last4=$4 WHERE id=$1`, uid, s.Box.Seal(phone), h, phone[7:])
	if db.IsUniqueViolation(err) {
		return httpx.Conflict("phone_taken", "这个手机号已经绑定了其他账号")
	}
	return err
}

type claims struct {
	jwt.RegisteredClaims
}

func (s *Service) issue(ctx context.Context, uid int64, family uuid.UUID, device string) (Result, error) {
	now := time.Now()
	tok := jwt.NewWithClaims(jwt.SigningMethodHS256, claims{jwt.RegisteredClaims{
		Subject: strconv.FormatInt(uid, 10), Audience: jwt.ClaimStrings{"app"},
		IssuedAt: jwt.NewNumericDate(now), ExpiresAt: jwt.NewNumericDate(now.Add(s.AccessTTL)),
	}})
	access, err := tok.SignedString(s.JWTSecret)
	if err != nil {
		return Result{}, err
	}
	refresh := secure.Token(32)
	if _, err := s.Pool.Exec(ctx, `INSERT INTO src.src_usr_loop_refresh_token (token_hash, family, user_id, device_id, expire_time) VALUES ($1,$2,$3,NULLIF($4,''),$5)`,
		secure.Hash(refresh), family, uid, device, now.Add(s.RefreshTTL)); err != nil {
		return Result{}, err
	}
	u, err := user.Load(ctx, s.Pool, s.Config, s.Box, uid)
	if err != nil {
		return Result{}, err
	}
	return Result{AccessToken: access, RefreshToken: refresh, ExpiresIn: int(s.AccessTTL.Seconds()), NeedBindPhone: !u.HasPhone, User: u}, nil
}

// Refresh rotates a refresh token. Reusing an already used token revokes the
// whole family (stolen token detection).
func (s *Service) Refresh(ctx context.Context, token string) (Result, error) {
	var uid int64
	var family uuid.UUID
	var device *string
	var exp time.Time
	var used, revoked *time.Time
	err := s.Pool.QueryRow(ctx, `SELECT user_id, family, device_id, expire_time, use_time, revoke_time FROM src.src_usr_loop_refresh_token WHERE token_hash=$1`,
		secure.Hash(token)).Scan(&uid, &family, &device, &exp, &used, &revoked)
	if db.IsNoRows(err) {
		return Result{}, httpx.ErrUnauthorized
	}
	if err != nil {
		return Result{}, err
	}
	if used != nil || revoked != nil {
		_, _ = s.Pool.Exec(ctx, `UPDATE src.src_usr_loop_refresh_token SET revoke_time=now() WHERE family=$1 AND revoke_time IS NULL`, family)
		return Result{}, httpx.ErrUnauthorized
	}
	if exp.Before(time.Now()) {
		return Result{}, httpx.ErrUnauthorized
	}
	tag, err := s.Pool.Exec(ctx, `UPDATE src.src_usr_loop_refresh_token SET use_time=now() WHERE token_hash=$1 AND use_time IS NULL`, secure.Hash(token))
	if err != nil {
		return Result{}, err
	}
	if tag.RowsAffected() == 0 {
		return Result{}, httpx.ErrUnauthorized
	}
	if err := s.checkStatus(ctx, uid); err != nil {
		return Result{}, err
	}
	d := ""
	if device != nil {
		d = *device
	}
	return s.issue(ctx, uid, family, d)
}

// Logout revokes the token's family.
func (s *Service) Logout(ctx context.Context, token string) error {
	_, err := s.Pool.Exec(ctx, `UPDATE src.src_usr_loop_refresh_token SET revoke_time=now() WHERE revoke_time IS NULL
		AND family=(SELECT family FROM src.src_usr_loop_refresh_token WHERE token_hash=$1)`, secure.Hash(token))
	return err
}

// RevokeAll signs a user out everywhere (ban, deletion).
func RevokeAll(ctx context.Context, q db.Querier, uid int64) error {
	_, err := q.Exec(ctx, `UPDATE src.src_usr_loop_refresh_token SET revoke_time=now() WHERE user_id=$1 AND revoke_time IS NULL`, uid)
	return err
}

// Parse validates an access token and returns the user id.
func (s *Service) Parse(token string) (int64, error) {
	var c claims
	_, err := jwt.ParseWithClaims(token, &c, func(*jwt.Token) (any, error) { return s.JWTSecret, nil },
		jwt.WithValidMethods([]string{"HS256"}), jwt.WithAudience("app"), jwt.WithExpirationRequired())
	if err != nil {
		return 0, err
	}
	return strconv.ParseInt(c.Subject, 10, 64)
}

// Middleware authenticates app requests. With requirePhone, accounts that
// have not bound a phone get 403 phone_required (实名制 requires a phone).
func (s *Service) Middleware(requirePhone bool) func(httpx.HandlerFunc) http.Handler {
	return func(h httpx.HandlerFunc) http.Handler {
		return httpx.Wrap(func(w http.ResponseWriter, r *http.Request) error {
			tok, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
			if !ok {
				return httpx.ErrUnauthorized
			}
			uid, err := s.Parse(tok)
			if err != nil {
				return httpx.ErrUnauthorized
			}
			var status string
			var hasPhone bool
			var bannedUntil *time.Time
			err = s.Pool.QueryRow(r.Context(), `SELECT status, phone_hash IS NOT NULL, ban_end_time FROM src.src_usr_loop_user WHERE id=$1`, uid).
				Scan(&status, &hasPhone, &bannedUntil)
			if db.IsNoRows(err) || status == "deleted" {
				return httpx.ErrUnauthorized
			}
			if err != nil {
				return err
			}
			if status == "banned" && (bannedUntil == nil || bannedUntil.After(time.Now())) {
				return httpx.Forbidden("account_banned", "账号已被封禁")
			}
			if requirePhone && !hasPhone {
				return httpx.Forbidden("phone_required", "请先绑定手机号")
			}
			return h(w, r.WithContext(httpx.WithUser(r.Context(), uid)))
		})
	}
}

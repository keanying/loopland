package media

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"io"
	"io/fs"
	"mime"
	"mime/multipart"
	"net/http"
	"os"
	"path"
	"slices"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/keanying/loopland/server/internal/platform/clock"
	"github.com/keanying/loopland/server/internal/platform/httpx"
)

// Limits (docs/api/v2-2-社区.md «图片上传», v2-6 «管理端图片上传»).
const (
	MaxBytes   = 10 << 20
	DailyLimit = 200
	// AdminDailyLimit is per back-office account (and per open platform app).
	AdminDailyLimit = 500
)

// App purposes.
var purposes = map[string]bool{"post": true, "avatar": true, "crew_avatar": true, "chat": true}

// AdminPurposes are the back-office purposes and the roles that may use
// them (merchant staff use venue_cover for their own venues only, which
// the venue endpoints enforce).
var AdminPurposes = map[string][]string{
	"product":          {"merchant"},
	"promotion_banner": {"admin", "ops"},
	"venue_cover":      {"admin", "ops", "merchant"},
	"merchant_license": {"admin", "ops"},
	"campaign_banner":  {"admin", "ops"},
	"shop_item":        {"admin", "ops"},
}

// ErrUnavailable is returned outside dev while OSS is not enabled.
var ErrUnavailable = httpx.E(http.StatusServiceUnavailable, "media_unavailable", "图片上传暂未开通")

// Handler serves /v1/media and /admin/v1/media; Accept serves /open/v1/media.
type Handler struct {
	Pool *pgxpool.Pool
	// Remote returns the enabled OSS store, or nil (管理端「系统配置」).
	Remote func() Store
	// Local is used when Remote is nil and Dev is true.
	Local Local
	Dev   bool
}

// Routes registers the endpoints. Files are public, like a CDN.
func (h *Handler) Routes(mux *http.ServeMux, auth func(httpx.HandlerFunc) http.Handler) {
	mux.Handle("POST /v1/media", auth(h.upload))
	mux.Handle("GET /v1/media/files/{path...}", http.HandlerFunc(h.file))
}

// AdminRoutes registers POST /admin/v1/media; anyAdmin admits every
// back-office role (the purpose decides).
func (h *Handler) AdminRoutes(mux *http.ServeMux, anyAdmin func(httpx.HandlerFunc) http.Handler) {
	mux.Handle("POST /admin/v1/media", anyAdmin(h.adminUpload))
}

func (h *Handler) store() (Store, error) {
	if h.Remote != nil {
		if s := h.Remote(); s != nil {
			return s, nil
		}
	}
	if !h.Dev {
		return nil, ErrUnavailable
	}
	return h.Local, nil
}

// Uploader is who uploads: an app user, a back-office account (with its
// merchant for merchant staff) or an open platform app (with its merchant).
type Uploader struct {
	UserID, AdminID, MerchantID, OpenAppID int64
}

// countSQL selects the uploader's uploads (daily limit).
func (u Uploader) countSQL() (string, int64) {
	switch {
	case u.UserID != 0:
		return `user_id=$1`, u.UserID
	case u.AdminID != 0:
		return `admin_id=$1`, u.AdminID
	case u.OpenAppID != 0:
		return `open_app_id=$1`, u.OpenAppID
	default:
		return `merchant_id=$1`, u.MerchantID
	}
}

func (h *Handler) upload(w http.ResponseWriter, r *http.Request) error {
	im, err := h.Accept(w, r, Uploader{UserID: httpx.UserID(r.Context())}, DailyLimit, func(purpose string) error {
		if !purposes[purpose] {
			return httpx.BadRequest("invalid_body", "purpose 取值错误")
		}
		return nil
	})
	if err != nil {
		return err
	}
	return httpx.OK(w, im)
}

func (h *Handler) adminUpload(w http.ResponseWriter, r *http.Request) error {
	ad, _ := httpx.AdminFrom(r.Context())
	up := Uploader{AdminID: ad.ID}
	if ad.Role == "merchant" {
		if ad.MerchantID == nil {
			return httpx.Forbidden("no_merchant", "这个商户账号还没有绑定商户")
		}
		up.MerchantID = *ad.MerchantID
	}
	im, err := h.Accept(w, r, up, AdminDailyLimit, func(purpose string) error {
		roles, ok := AdminPurposes[purpose]
		if !ok {
			return httpx.BadRequest("invalid_body", "purpose 取值错误")
		}
		if !slices.Contains(roles, ad.Role) {
			return httpx.Forbidden("forbidden", "当前账号不能上传这类图片")
		}
		return nil
	})
	if err != nil {
		return err
	}
	return httpx.OK(w, im)
}

// Accept reads a multipart upload (purpose, file), checks the purpose,
// the type (by content) and the uploader's daily limit, then stores it.
func (h *Handler) Accept(w http.ResponseWriter, r *http.Request, up Uploader, limit int, check func(purpose string) error) (Image, error) {
	st, err := h.store()
	if err != nil {
		return Image{}, err
	}
	r.Body = http.MaxBytesReader(w, r.Body, MaxBytes+1<<20)
	purpose, data, err := readForm(r)
	if err != nil {
		return Image{}, err
	}
	if err := check(purpose); err != nil {
		return Image{}, err
	}
	ct := Sniff(data)
	if ct == "" {
		return Image{}, httpx.BadRequest("unsupported_media", "只支持 jpg、png、webp、heic 图片")
	}
	where, id := up.countSQL()
	var today int
	if err := h.Pool.QueryRow(r.Context(), `SELECT count(*) FROM src.src_cnt_loop_media WHERE `+where+` AND create_time >= $2`, id, clock.Today()).Scan(&today); err != nil {
		return Image{}, err
	}
	if today >= limit {
		return Image{}, httpx.E(http.StatusTooManyRequests, "rate_limited", "今天上传的图片太多了，明天再来")
	}
	return Save(r.Context(), h.Pool, st, up, purpose, ct, data)
}

func nullID(v int64) any {
	if v == 0 {
		return nil
	}
	return v
}

// Save stores bytes of a sniffed type and records the row.
func Save(ctx context.Context, pool *pgxpool.Pool, st Store, up Uploader, purpose, ct string, data []byte) (Image, error) {
	var im Image
	if wd, ht, ok := Dimensions(data, ct); ok {
		im.Width, im.Height = &wd, &ht
	}
	rnd := make([]byte, 12)
	_, _ = rand.Read(rnd)
	key := purpose + "/" + clock.Now().In(clock.Shanghai).Format("2006/01/02") + "/" + hex.EncodeToString(rnd) + "." + extOf[ct]
	url, err := st.Put(ctx, key, ct, data)
	if err != nil {
		return im, err
	}
	im.URL = url
	err = pool.QueryRow(ctx, `INSERT INTO src.src_cnt_loop_media (user_id, admin_id, merchant_id, open_app_id, purpose_type, storage_type, object_key, url,
			content_type, size_byte_qty, width_px, height_px)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12) RETURNING id`, nullID(up.UserID), nullID(up.AdminID), nullID(up.MerchantID), nullID(up.OpenAppID),
		purpose, st.Kind(), key, url, ct, len(data), im.Width, im.Height).Scan(&im.ID)
	return im, err
}

// readForm reads the purpose field and the file part (streamed, size-capped).
func readForm(r *http.Request) (purpose string, data []byte, err error) {
	if mt, _, _ := mime.ParseMediaType(r.Header.Get("Content-Type")); mt != "multipart/form-data" {
		return "", nil, httpx.BadRequest("invalid_body", "请用 multipart/form-data 上传")
	}
	mr, err := r.MultipartReader()
	if err != nil {
		return "", nil, httpx.BadRequest("invalid_body", "上传格式错误")
	}
	for {
		p, err := mr.NextPart()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return "", nil, tooLargeOr(err, httpx.BadRequest("invalid_body", "上传格式错误"))
		}
		switch p.FormName() {
		case "purpose":
			b, err := io.ReadAll(io.LimitReader(p, 64))
			if err != nil {
				return "", nil, tooLargeOr(err, httpx.BadRequest("invalid_body", "上传格式错误"))
			}
			purpose = string(b)
		case "file":
			data, err = readFile(p)
			if err != nil {
				return "", nil, err
			}
		}
		_ = p.Close()
	}
	if data == nil {
		return "", nil, httpx.BadRequest("invalid_body", "缺少 file")
	}
	return purpose, data, nil
}

var ErrTooLarge = httpx.E(http.StatusRequestEntityTooLarge, "file_too_large", "图片不能超过 10 MB")

func readFile(p *multipart.Part) ([]byte, error) {
	b, err := io.ReadAll(io.LimitReader(p, MaxBytes+1))
	if err != nil {
		return nil, tooLargeOr(err, httpx.BadRequest("invalid_body", "上传格式错误"))
	}
	if len(b) > MaxBytes {
		return nil, ErrTooLarge
	}
	if len(b) == 0 {
		return nil, httpx.BadRequest("invalid_body", "文件为空")
	}
	return b, nil
}

func tooLargeOr(err error, other error) error {
	var mb *http.MaxBytesError
	if errors.As(err, &mb) {
		return ErrTooLarge
	}
	return other
}

// file serves a locally stored upload.
func (h *Handler) file(w http.ResponseWriter, r *http.Request) {
	key := r.PathValue("path")
	if !validKey(key) || h.Local.Dir == "" {
		http.NotFound(w, r)
		return
	}
	root, err := os.OpenRoot(h.Local.Dir)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	defer root.Close()
	f, err := root.Open(key)
	if err != nil {
		if !errors.Is(err, fs.ErrNotExist) {
			httpx.Logger.Error("media file", "key", key, "err", err)
		}
		http.NotFound(w, r)
		return
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil || info.IsDir() {
		http.NotFound(w, r)
		return
	}
	ct := "application/octet-stream"
	for t, ext := range extOf {
		if path.Ext(key) == "."+ext {
			ct = t
		}
	}
	w.Header().Set("Content-Type", ct)
	w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
	http.ServeContent(w, r, "", info.ModTime().Truncate(time.Second), f)
}

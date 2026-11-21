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
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/keanying/loopland/server/internal/platform/clock"
	"github.com/keanying/loopland/server/internal/platform/httpx"
)

// Limits (docs/api/v2-2-社区.md «图片上传»).
const (
	MaxBytes   = 10 << 20
	DailyLimit = 200
)

// Purposes.
var purposes = map[string]bool{"post": true, "avatar": true, "crew_avatar": true, "chat": true}

// ErrUnavailable is returned outside dev while OSS is not enabled.
var ErrUnavailable = httpx.E(http.StatusServiceUnavailable, "media_unavailable", "图片上传暂未开通")

// Handler serves /v1/media.
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

func (h *Handler) upload(w http.ResponseWriter, r *http.Request) error {
	uid := httpx.UserID(r.Context())
	st, err := h.store()
	if err != nil {
		return err
	}
	r.Body = http.MaxBytesReader(w, r.Body, MaxBytes+1<<20)
	purpose, data, err := readForm(r)
	if err != nil {
		return err
	}
	if !purposes[purpose] {
		return httpx.BadRequest("invalid_body", "purpose 取值错误")
	}
	ct := Sniff(data)
	if ct == "" {
		return httpx.BadRequest("unsupported_media", "只支持 jpg、png、webp、heic 图片")
	}
	var today int
	if err := h.Pool.QueryRow(r.Context(), `SELECT count(*) FROM src.src_cnt_loop_media WHERE user_id=$1 AND create_time >= $2`, uid, clock.Today()).Scan(&today); err != nil {
		return err
	}
	if today >= DailyLimit {
		return httpx.E(http.StatusTooManyRequests, "rate_limited", "今天上传的图片太多了，明天再来")
	}
	im, err := Save(r.Context(), h.Pool, st, uid, purpose, ct, data)
	if err != nil {
		return err
	}
	return httpx.OK(w, im)
}

// Save stores bytes of a sniffed type and records the row.
func Save(ctx context.Context, pool *pgxpool.Pool, st Store, uid int64, purpose, ct string, data []byte) (Image, error) {
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
	err = pool.QueryRow(ctx, `INSERT INTO src.src_cnt_loop_media (user_id, purpose_type, storage_type, object_key, url, content_type, size_byte_qty, width_px, height_px)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9) RETURNING id`, uid, purpose, st.Kind(), key, url, ct, len(data), im.Width, im.Height).Scan(&im.ID)
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

var errTooLarge = httpx.E(http.StatusRequestEntityTooLarge, "file_too_large", "图片不能超过 10 MB")

func readFile(p *multipart.Part) ([]byte, error) {
	b, err := io.ReadAll(io.LimitReader(p, MaxBytes+1))
	if err != nil {
		return nil, tooLargeOr(err, httpx.BadRequest("invalid_body", "上传格式错误"))
	}
	if len(b) > MaxBytes {
		return nil, errTooLarge
	}
	if len(b) == 0 {
		return nil, httpx.BadRequest("invalid_body", "文件为空")
	}
	return b, nil
}

func tooLargeOr(err error, other error) error {
	var mb *http.MaxBytesError
	if errors.As(err, &mb) {
		return errTooLarge
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

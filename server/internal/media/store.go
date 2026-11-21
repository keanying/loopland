package media

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/aliyun/alibabacloud-oss-go-sdk-v2/oss"
	"github.com/aliyun/alibabacloud-oss-go-sdk-v2/oss/credentials"
)

// Store keeps uploaded bytes and returns their public URL.
type Store interface {
	// Kind is the storage_type stored with the row: local | oss.
	Kind() string
	Put(ctx context.Context, key, contentType string, body []byte) (url string, err error)
}

// Local stores files under Dir and serves them at
// BaseURL/v1/media/files/<key> (dev, without OSS).
type Local struct {
	Dir     string
	BaseURL string
}

// Kind implements Store.
func (Local) Kind() string { return "local" }

// Put implements Store.
func (l Local) Put(_ context.Context, key, _ string, body []byte) (string, error) {
	if !validKey(key) {
		return "", fmt.Errorf("invalid media key %q", key)
	}
	p := filepath.Join(l.Dir, filepath.FromSlash(key))
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return "", err
	}
	tmp := p + ".part"
	if err := os.WriteFile(tmp, body, 0o644); err != nil {
		return "", err
	}
	if err := os.Rename(tmp, p); err != nil {
		return "", err
	}
	return strings.TrimRight(l.BaseURL, "/") + "/v1/media/files/" + key, nil
}

// validKey accepts the keys this package generates: lowercase letters,
// digits, '_', '-', '.' and '/' separators, no empty or dot segments.
func validKey(key string) bool {
	if key == "" || len(key) > 200 {
		return false
	}
	for _, seg := range strings.Split(key, "/") {
		if seg == "" || seg == "." || seg == ".." || strings.HasPrefix(seg, ".") {
			return false
		}
		for _, r := range seg {
			if !(r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '_' || r == '-' || r == '.') {
				return false
			}
		}
	}
	return true
}

// OSS stores files in an Aliyun OSS bucket (对象存储 OSS, 管理端「系统配置」).
type OSS struct {
	client *oss.Client
	bucket string
	base   string
}

// NewOSS builds the client. endpoint may be empty (derived from region);
// publicBase is the CDN / custom domain, empty for the bucket's own domain.
func NewOSS(region, endpoint, bucket, publicBase, keyID, keySecret string) (*OSS, error) {
	region = strings.TrimPrefix(strings.TrimSpace(region), "oss-")
	bucket = strings.TrimSpace(bucket)
	if region == "" || bucket == "" || keyID == "" || keySecret == "" {
		return nil, fmt.Errorf("OSS 地域、Bucket 和阿里云 AccessKey 必须填写")
	}
	cfg := oss.LoadDefaultConfig().
		WithCredentialsProvider(credentials.NewStaticCredentialsProvider(keyID, keySecret)).
		WithRegion(region).
		WithConnectTimeout(5 * time.Second).
		WithReadWriteTimeout(30 * time.Second)
	host := "oss-" + region + ".aliyuncs.com"
	if endpoint = strings.TrimSpace(endpoint); endpoint != "" {
		cfg = cfg.WithEndpoint(endpoint)
		host = strings.TrimPrefix(strings.TrimPrefix(endpoint, "https://"), "http://")
	}
	if publicBase = strings.TrimRight(strings.TrimSpace(publicBase), "/"); publicBase == "" {
		publicBase = "https://" + bucket + "." + strings.TrimRight(host, "/")
	}
	return &OSS{client: oss.NewClient(cfg), bucket: bucket, base: publicBase}, nil
}

// Kind implements Store.
func (*OSS) Kind() string { return "oss" }

// Put implements Store.
func (o *OSS) Put(ctx context.Context, key, contentType string, body []byte) (string, error) {
	_, err := o.client.PutObject(ctx, &oss.PutObjectRequest{
		Bucket:       oss.Ptr(o.bucket),
		Key:          oss.Ptr(key),
		Body:         bytes.NewReader(body),
		ContentType:  oss.Ptr(contentType),
		CacheControl: oss.Ptr("public, max-age=31536000, immutable"),
	})
	if err != nil {
		return "", err
	}
	return o.base + "/" + key, nil
}

// Check writes a tiny object: proves the key, the bucket and the write
// permission the uploads need.
func (o *OSS) Check(ctx context.Context) error {
	_, err := o.Put(ctx, "_loopland/check.txt", "text/plain", []byte("loopland connection test "+time.Now().Format(time.RFC3339)))
	return err
}

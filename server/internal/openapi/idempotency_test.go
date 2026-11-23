package openapi

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"
)

func testRedis(t *testing.T) *redis.Client {
	url := os.Getenv("LOOPLAND_TEST_REDIS_URL")
	if url == "" {
		url = "redis://localhost:6378/15"
	}
	opts, err := redis.ParseURL(url)
	if err != nil {
		t.Fatal(err)
	}
	rdb := redis.NewClient(opts)
	if err := rdb.Ping(context.Background()).Err(); err != nil {
		if os.Getenv("LOOPLAND_TEST_REQUIRE_DB") == "1" {
			t.Fatal(err)
		}
		t.Skip("no redis:", err)
	}
	return rdb
}

// A handler that panics must not leave its Idempotency-Key locked as
// "in progress": the key is released and a retry with the same key runs.
func TestIdempotencyKeyReleasedOnPanic(t *testing.T) {
	rdb := testRedis(t)
	s := &Service{Redis: rdb}
	const app = int64(987654)
	key := "open:idem:987654:panic-1"
	rdb.Del(context.Background(), key)
	t.Cleanup(func() { rdb.Del(context.Background(), key) })

	run := func(h func(http.ResponseWriter, *http.Request) error) (rec *httptest.ResponseRecorder, panicked bool) {
		rec = httptest.NewRecorder()
		r := httptest.NewRequest(http.MethodPost, "/open/v1/products", nil)
		defer func() {
			if recover() != nil {
				panicked = true
			}
		}()
		_ = s.idempotent(&recorder{ResponseWriter: rec}, r, app, "panic-1", h)
		return rec, false
	}

	if _, panicked := run(func(http.ResponseWriter, *http.Request) error { panic("boom") }); !panicked {
		t.Fatal("panic was swallowed")
	}
	if n, _ := rdb.Exists(context.Background(), key).Result(); n != 0 {
		t.Fatal("key still locked after panic")
	}

	rec, _ := run(func(w http.ResponseWriter, _ *http.Request) error {
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{"id":1}`))
		return nil
	})
	if rec.Code != http.StatusCreated {
		t.Fatalf("retry after panic: %d %s", rec.Code, rec.Body.String())
	}
	// The stored result now lives for the full TTL and replays.
	if ttl, _ := rdb.TTL(context.Background(), key).Result(); ttl < IdempotencyTTL-time.Minute {
		t.Fatalf("result TTL %v, want ~%v", ttl, IdempotencyTTL)
	}
	rec, _ = run(func(http.ResponseWriter, *http.Request) error { t.Fatal("ran twice"); return nil })
	if rec.Code != http.StatusCreated || rec.Header().Get("Idempotent-Replayed") != "true" {
		t.Fatalf("replay: %d %v", rec.Code, rec.Header())
	}
}

// The "in progress" marker expires quickly, so a process that dies mid-request
// does not block the key for 24 hours.
func TestIdempotencyPendingMarkerIsShortLived(t *testing.T) {
	if IdempotencyPendingTTL > 5*time.Minute {
		t.Fatalf("pending TTL %v too long", IdempotencyPendingTTL)
	}
}

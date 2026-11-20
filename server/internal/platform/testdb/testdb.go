// Package testdb gives integration tests a fresh, migrated PostGIS database.
//
// Tests use LOOPLAND_TEST_DATABASE_URL (default: local loopland superuser).
// When no server is reachable the test is skipped, unless LOOPLAND_TEST_REQUIRE_DB=1
// (set in CI) makes it fail instead.
package testdb

import (
	"context"
	"fmt"
	"math/rand/v2"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/keanying/loopland/server/internal/platform/db"
)

// New creates a database, migrates it and drops it when the test ends.
func New(t testing.TB) *pgxpool.Pool {
	t.Helper()
	base := os.Getenv("LOOPLAND_TEST_DATABASE_URL")
	if base == "" {
		base = "postgres://loopland:loopland@localhost:5432/postgres?sslmode=disable"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	admin, err := db.Open(ctx, base)
	if err != nil {
		if os.Getenv("LOOPLAND_TEST_REQUIRE_DB") == "1" {
			t.Fatalf("database required: %v", err)
		}
		t.Skipf("no test database: %v", err)
	}
	name := fmt.Sprintf("lp_test_%d_%d", time.Now().UnixNano(), rand.IntN(1e6))
	if _, err := admin.Exec(ctx, "CREATE DATABASE "+name); err != nil {
		admin.Close()
		t.Fatal(err)
	}
	url := replaceDB(base, name)
	pool, err := db.Open(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	if err := db.Migrate(ctx, pool); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		pool.Close()
		_, _ = admin.Exec(context.Background(), "DROP DATABASE IF EXISTS "+name+" WITH (FORCE)")
		admin.Close()
	})
	return pool
}

func replaceDB(url, name string) string {
	q := ""
	if i := strings.Index(url, "?"); i >= 0 {
		url, q = url[:i], url[i:]
	}
	i := strings.LastIndex(url, "/")
	return url[:i+1] + name + q
}

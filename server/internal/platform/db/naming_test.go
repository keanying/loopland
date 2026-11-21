package db_test

import (
	"context"
	"regexp"
	"testing"

	"github.com/keanying/loopland/server/internal/platform/testdb"
)

// TestNamingStandard enforces docs/数据库与命名规范.md on the migrated
// schema: every table in src is named src_<domain>_loop_<entity>, and every table
// and column carries a comment.
func TestNamingStandard(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	domains := `(usr|act|ter|ply|soc|ord|fin|mer|mkt|ris|cnt|msg|trf|sys)`
	tableRe := regexp.MustCompile(`^src_` + domains + `_loop_[a-z0-9_]+$`)
	rows, err := pool.Query(ctx, `SELECT c.relname, obj_description(c.oid, 'pg_class') IS NOT NULL
		FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
		WHERE n.nspname='src' AND c.relkind IN ('r','p')`)
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	for rows.Next() {
		var name string
		var commented bool
		if err := rows.Scan(&name, &commented); err != nil {
			t.Fatal(err)
		}
		n++
		if !tableRe.MatchString(name) {
			t.Errorf("table %s does not follow src_<domain>_loop_<entity>", name)
		}
		if !commented {
			t.Errorf("table %s has no comment", name)
		}
	}
	rows.Close()
	if n < 40 {
		t.Fatalf("only %d tables found in schema src", n)
	}
	rows, err = pool.Query(ctx, `SELECT c.relname, a.attname FROM pg_attribute a
		JOIN pg_class c ON c.oid=a.attrelid JOIN pg_namespace n ON n.oid=c.relnamespace
		WHERE n.nspname='src' AND c.relkind IN ('r','p') AND NOT c.relispartition AND a.attnum > 0 AND NOT a.attisdropped
		  AND col_description(c.oid, a.attnum) IS NULL`)
	if err != nil {
		t.Fatal(err)
	}
	for rows.Next() {
		var tbl, col string
		if err := rows.Scan(&tbl, &col); err != nil {
			t.Fatal(err)
		}
		t.Errorf("column %s.%s has no comment", tbl, col)
	}
	rows.Close()
	// Time columns are timestamptz and end in _time; amounts end in _amt.
	rows, err = pool.Query(ctx, `SELECT table_name, column_name, data_type FROM information_schema.columns
		WHERE table_schema='src' AND ((data_type LIKE 'timestamp%' AND column_name NOT LIKE '%\_time')
		   OR column_name LIKE '%\_at' OR column_name LIKE '%\_fen')`)
	if err != nil {
		t.Fatal(err)
	}
	for rows.Next() {
		var tbl, col, typ string
		if err := rows.Scan(&tbl, &col, &typ); err != nil {
			t.Fatal(err)
		}
		t.Errorf("column %s.%s (%s) breaks the _time / _amt rule", tbl, col, typ)
	}
	rows.Close()
}

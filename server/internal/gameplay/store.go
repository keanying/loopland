package gameplay

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Version is one published configuration.
type Version struct {
	ID          int64     `json:"-"`
	Version     string    `json:"version"`
	Body        Config    `json:"body"`
	RolloutPct  int       `json:"rollout_pct"`
	Note        string    `json:"note"`
	PublishedBy *int64    `json:"published_by"`
	PublishedAt time.Time `json:"published_at"`
}

// Store serves the live configuration with percentage rollout: while the
// newest version is below 100%, users outside its bucket keep the previous
// version (功能清单 M-32: 先发 10% 用户再全量).
type Store struct {
	pool *pgxpool.Pool

	mu       sync.RWMutex
	current  Version
	previous *Version
}

// NewStore loads the configuration, seeding the defaults on first start.
func NewStore(ctx context.Context, pool *pgxpool.Pool) (*Store, error) {
	s := &Store{pool: pool}
	if err := s.seed(ctx); err != nil {
		return nil, err
	}
	return s, s.Reload(ctx)
}

// NewStatic serves a fixed configuration (tests, tools).
func NewStatic(c Config) *Store {
	return &Store{current: Version{Version: c.Version, Body: c, RolloutPct: 100}}
}

func (s *Store) seed(ctx context.Context) error {
	d := Default()
	body, _ := json.Marshal(d)
	_, err := s.pool.Exec(ctx, `INSERT INTO src.src_sys_loop_gameplay_config (version, config_json, rollout_pct, note)
		SELECT $1, $2, 100, '初始数值' WHERE NOT EXISTS (SELECT 1 FROM src.src_sys_loop_gameplay_config)`, d.Version, body)
	return err
}

// Reload refreshes from the database (called periodically and after writes).
func (s *Store) Reload(ctx context.Context) error {
	if s.pool == nil {
		return nil
	}
	rows, err := s.pool.Query(ctx, `SELECT id, version, config_json, rollout_pct, COALESCE(note,''), published_by, publish_time
		FROM src.src_sys_loop_gameplay_config WHERE rollback_time IS NULL ORDER BY id DESC LIMIT 2`)
	if err != nil {
		return err
	}
	vs, err := pgx.CollectRows(rows, scanVersion)
	if err != nil {
		return err
	}
	if len(vs) == 0 {
		return fmt.Errorf("no gameplay config")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.current = vs[0]
	s.previous = nil
	if len(vs) > 1 {
		s.previous = &vs[1]
	}
	return nil
}

func scanVersion(row pgx.CollectableRow) (Version, error) {
	var v Version
	var body []byte
	if err := row.Scan(&v.ID, &v.Version, &body, &v.RolloutPct, &v.Note, &v.PublishedBy, &v.PublishedAt); err != nil {
		return v, err
	}
	if err := json.Unmarshal(body, &v.Body); err != nil {
		return v, err
	}
	v.Body.Normalize()
	v.Body.Version = v.Version
	return v, nil
}

// For returns the configuration a given user sees.
func (s *Store) For(userID int64) Config {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.current.RolloutPct < 100 && s.previous != nil && userID%100 >= int64(s.current.RolloutPct) {
		return s.previous.Body
	}
	return s.current.Body
}

// Current returns the newest version and the one before it.
func (s *Store) Current() (Version, *Version) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.current, s.previous
}

// History lists published versions, newest first.
func (s *Store) History(ctx context.Context) ([]Version, error) {
	rows, err := s.pool.Query(ctx, `SELECT id, version, config_json, rollout_pct, COALESCE(note,''), published_by, publish_time
		FROM src.src_sys_loop_gameplay_config ORDER BY id DESC LIMIT 50`)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, scanVersion)
}

// Publish validates and stores a new version.
func (s *Store) Publish(ctx context.Context, body Config, note string, rolloutPct int, adminID int64) (Version, error) {
	if rolloutPct < 1 || rolloutPct > 100 {
		return Version{}, fmt.Errorf("rollout_pct must be 1..100")
	}
	if err := body.Validate(); err != nil {
		return Version{}, err
	}
	cur, _ := s.Current()
	body.Version = nextVersion(cur.Version)
	raw, _ := json.Marshal(body)
	if _, err := s.pool.Exec(ctx, `INSERT INTO src.src_sys_loop_gameplay_config (version, config_json, rollout_pct, note, published_by) VALUES ($1,$2,$3,$4,$5)`,
		body.Version, raw, rolloutPct, note, adminID); err != nil {
		return Version{}, err
	}
	if err := s.Reload(ctx); err != nil {
		return Version{}, err
	}
	v, _ := s.Current()
	return v, nil
}

// Rollout changes the current version's percentage.
func (s *Store) Rollout(ctx context.Context, pct int) error {
	if pct < 1 || pct > 100 {
		return fmt.Errorf("rollout_pct must be 1..100")
	}
	cur, _ := s.Current()
	if _, err := s.pool.Exec(ctx, `UPDATE src.src_sys_loop_gameplay_config SET rollout_pct=$1 WHERE id=$2`, pct, cur.ID); err != nil {
		return err
	}
	return s.Reload(ctx)
}

// Rollback withdraws the current version; the previous one becomes current
// at 100%.
func (s *Store) Rollback(ctx context.Context) error {
	cur, prev := s.Current()
	if prev == nil {
		return fmt.Errorf("没有可以回滚到的版本")
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	if _, err := tx.Exec(ctx, `UPDATE src.src_sys_loop_gameplay_config SET rollback_time=now() WHERE id=$1`, cur.ID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `UPDATE src.src_sys_loop_gameplay_config SET rollout_pct=100 WHERE id=$1`, prev.ID); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return err
	}
	return s.Reload(ctx)
}

// Watch reloads periodically so every instance converges after a publish.
func (s *Store) Watch(ctx context.Context, every time.Duration) {
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			_ = s.Reload(ctx)
		}
	}
}

// nextVersion bumps the last numeric component: v3.12 → v3.13.
func nextVersion(v string) string {
	i := strings.LastIndexAny(v, ".")
	if i >= 0 {
		if n, err := strconv.Atoi(v[i+1:]); err == nil {
			return v[:i+1] + strconv.Itoa(n+1)
		}
	}
	return v + ".1"
}

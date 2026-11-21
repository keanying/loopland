#!/usr/bin/env bash
# 圈圈 Loopland 本地开发脚本（Linux / macOS）。Windows 请用 scripts/dev.ps1。
#
#   scripts/dev.sh check        检查 Go / Node / Flutter / Docker / psql 是否装好
#   scripts/dev.sh deps         用 Docker 启动 PostgreSQL+PostGIS 和 Redis
#   scripts/dev.sh db-init      不用 Docker 时：在本机 PostgreSQL 里建用户、库和 PostGIS
#   scripts/dev.sh api          启动后端（dev 模式，:8080）
#   scripts/dev.sh seed         灌演示数据（后端需已启动）
#   scripts/dev.sh admin        启动管理端（:5173，代理到后端）
#   scripts/dev.sh admin-mock   启动管理端的离线模拟数据模式（不需要后端）
#   scripts/dev.sh app [设备]   启动 App（flutter run；设备可省略，如 chrome、emulator-5554）
#   scripts/dev.sh doctor       检查后端配置和各第三方服务
#   scripts/dev.sh test         跑后端、管理端、App 全部测试
#   scripts/dev.sh all          deps + api（后台）+ seed + admin
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
API_PORT="${LOOPLAND_API_PORT:-8080}"
export LOOPLAND_ENV="${LOOPLAND_ENV:-dev}"
export LOOPLAND_HTTP_ADDR="${LOOPLAND_HTTP_ADDR:-:$API_PORT}"
export LOOPLAND_DATABASE_URL="${LOOPLAND_DATABASE_URL:-postgres://loopland:loopland@localhost:5432/loopland?sslmode=disable}"
export LOOPLAND_REDIS_URL="${LOOPLAND_REDIS_URL:-redis://localhost:6379/0}"
export LOOPLAND_BOOTSTRAP_ADMIN="${LOOPLAND_BOOTSTRAP_ADMIN:-admin:admin-password-1}"

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m错误：\033[0m%s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

compose() {
  if docker compose version >/dev/null 2>&1; then docker compose -f "$ROOT/deploy/docker-compose.yml" "$@"
  elif have docker-compose; then docker-compose -f "$ROOT/deploy/docker-compose.yml" "$@"
  else die "没有找到 docker compose。安装 Docker，或者自己装 PostgreSQL 16 + PostGIS 和 Redis 后运行 db-init"; fi
}

wait_api() {
  for _ in $(seq 1 60); do
    curl -fsS "http://localhost:$API_PORT/healthz" >/dev/null 2>&1 && return 0
    sleep 1
  done
  die "后端 60 秒内没有启动，看看上面的日志"
}

cmd_check() {
  local ok=1
  for t in go node npm flutter docker psql curl; do
    if have "$t"; then printf '  ✓ %-8s %s\n' "$t" "$("$t" --version 2>/dev/null | head -1)"
    else printf '  ✗ %-8s 未安装\n' "$t"; ok=0; fi
  done
  echo
  echo "需要：Go ≥ 1.26（后端）、Node 22（管理端）、Flutter 3.50（App）；数据库用 Docker 或本机 PostgreSQL 16 + PostGIS 3 + Redis 7。"
  [ "$ok" = 1 ] || echo "缺的工具只影响对应那一端。"
}

cmd_deps() {
  say "启动 PostgreSQL+PostGIS 和 Redis（Docker）"
  compose up -d postgres redis
  say "等待数据库就绪"
  for _ in $(seq 1 60); do
    compose exec -T postgres pg_isready -U loopland >/dev/null 2>&1 && { say "数据库就绪"; return; }
    sleep 1
  done
  die "数据库 60 秒内没有就绪"
}

cmd_db_init() {
  have psql || die "需要 psql"
  local su="${PGSUPERUSER:-postgres}"
  say "用超级用户 $su 创建 loopland 用户、loopland 库和 PostGIS 扩展（已存在则跳过）"
  psql -U "$su" -h "${PGHOST:-localhost}" -d postgres -v ON_ERROR_STOP=1 <<'SQL'
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='loopland') THEN CREATE ROLE loopland LOGIN PASSWORD 'loopland' CREATEDB; END IF;
END $$;
SELECT 'CREATE DATABASE loopland OWNER loopland' WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname='loopland')\gexec
SQL
  psql -U "$su" -h "${PGHOST:-localhost}" -d loopland -v ON_ERROR_STOP=1 -c 'CREATE EXTENSION IF NOT EXISTS postgis'
  say "完成。后端启动时会自动建表。"
}

cmd_api() {
  say "启动后端 http://localhost:$API_PORT （管理员 ${LOOPLAND_BOOTSTRAP_ADMIN%%:*}）"
  cd "$ROOT/server" && exec go run ./cmd/loopland-api
}

cmd_seed() {
  wait_api
  say "灌演示数据"
  cd "$ROOT/server" && go run ./cmd/loopland-seed -api "http://localhost:$API_PORT" -admin "$LOOPLAND_BOOTSTRAP_ADMIN"
}

npm_ready() {
  cd "$ROOT/admin"
  [ -d node_modules ] || { say "安装管理端依赖"; npm ci; }
}

cmd_admin() {
  npm_ready
  say "启动管理端（端口、后端地址等见 admin/config.yaml，本机覆盖写 admin/config.local.yaml）"
  exec npm run dev
}

cmd_admin_mock() {
  npm_ready
  say "启动管理端（模拟数据，不需要后端）http://localhost:5173"
  exec npm run dev:mock
}

cmd_app() {
  cd "$ROOT/app"
  flutter pub get
  local profile="${LOOPLAND_APP_PROFILE:-dev}"
  # 配置统一在 app/config/app.yaml（本机覆盖写 app.local.yaml），这里生成各端用的配置文件。
  local gen=(run tool/gen_config.dart --profile "$profile")
  if [[ "${1:-}" == emulator-* ]] && [ ! -f config/app.local.yaml ]; then
    gen+=(--api-base "http://10.0.2.2:$API_PORT") # Android 模拟器访问电脑上的后端
  fi
  dart "${gen[@]}"
  local args=(--dart-define-from-file="config/$profile.json")
  [ "${1:-}" != "" ] && args+=(-d "$1")
  exec flutter run "${args[@]}"
}

cmd_doctor() { cd "$ROOT/server" && go run ./cmd/loopland-doctor; }

cmd_test() {
  say "后端测试（需要 PostgreSQL 和 Redis）"
  (cd "$ROOT/server" && go vet ./... && go test ./...)
  say "管理端检查"
  npm_ready
  (cd "$ROOT/admin" && npm run lint && npm run build)
  if have flutter; then
    say "App 检查"
    (cd "$ROOT/app" && flutter pub get && flutter analyze && flutter test)
  else
    echo "未安装 Flutter，跳过 App"
  fi
}

cmd_all() {
  cmd_deps
  say "后台启动后端，日志写到 server/api.log"
  (cd "$ROOT/server" && nohup go run ./cmd/loopland-api >api.log 2>&1 &)
  cmd_seed
  cmd_admin
}

case "${1:-}" in
  check) cmd_check ;;
  deps) cmd_deps ;;
  db-init) cmd_db_init ;;
  api) cmd_api ;;
  seed) cmd_seed ;;
  admin) cmd_admin ;;
  admin-mock) cmd_admin_mock ;;
  app) shift; cmd_app "${1:-}" ;;
  doctor) cmd_doctor ;;
  test) cmd_test ;;
  all) cmd_all ;;
  *) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac

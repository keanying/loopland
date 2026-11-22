#!/usr/bin/env bash
# 圈圈 Loopland 一键安装与启动（Linux：Ubuntu / Debian；macOS：需要 Homebrew）。Windows 用 scripts/setup.ps1。
#
# 从零开始：装工具 → 配国内镜像 → 装项目依赖 → 启动数据库 → 启动后端、灌演示数据、启动管理端。
# 可以重复运行：已经装好的会跳过。工具装在 ~/dev 下（Go、Node、Flutter），不改系统目录；
# 只有 apt / brew 安装 git、curl、Docker 时需要 sudo。
#
#   scripts/setup.sh                  全部做完并启动
#   scripts/setup.sh --no-start       只装环境和依赖，不启动
#   scripts/setup.sh --no-docker      不用 Docker：用本机 PostgreSQL(PostGIS) + Redis（会运行 db-init）
#   scripts/setup.sh --no-mirror      不配置国内镜像（海外网络）
#   scripts/setup.sh --app chrome     最后再启动 App（chrome / linux / macos / 设备 ID）
#   LOOPLAND_TOOLS=~/tools scripts/setup.sh   工具装到别的目录
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="${LOOPLAND_TOOLS:-$HOME/dev}"
NEED_GO=1.26
NEED_NODE=22
NEED_FLUTTER=3.50
PNPM_VERSION=10.28.0
NO_START=0 NO_DOCKER=0 NO_MIRROR=0 APP_DEVICE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --no-start) NO_START=1 ;;
    --no-docker) NO_DOCKER=1 ;;
    --no-mirror) NO_MIRROR=1 ;;
    --app) shift; APP_DEVICE="${1:-}" ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "未知参数：$1（--help 查看用法）" >&2; exit 2 ;;
  esac
  shift
done

say() { printf '\n\033[32m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '    \033[33m! %s\033[0m\n' "$*"; }
die() { printf '\n\033[31m错误：%s\033[0m\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
# ver_ge 1.27 1.26 → true
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }

OS="$(uname -s)"
ARCH="$(uname -m)"
case "$ARCH" in x86_64|amd64) GOARCH=amd64 NODEARCH=x64 ;; aarch64|arm64) GOARCH=arm64 NODEARCH=arm64 ;; *) die "不支持的 CPU 架构：$ARCH" ;; esac
case "$OS" in Linux) GOOS=linux NODEOS=linux ;; Darwin) GOOS=darwin NODEOS=darwin ;; *) die "不支持的系统：$OS（Windows 请用 scripts/setup.ps1）" ;; esac
SUDO=""; [ "$(id -u)" -ne 0 ] && have sudo && SUDO="sudo"

# 环境变量写进 ~/.loopland_env，并让 ~/.bashrc / ~/.zshrc 读取它（以后新开终端也生效）
ENV_FILE="$HOME/.loopland_env"
write_env() {
  {
    echo "# 圈圈 Loopland 开发环境（scripts/setup.sh 生成，可以手改）"
    if [ "$NO_MIRROR" = 0 ]; then
      echo "export PUB_HOSTED_URL=https://pub.flutter-io.cn"
      echo "export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn"
      echo "export GOPROXY=https://goproxy.cn,direct"
      echo "export COREPACK_NPM_REGISTRY=https://registry.npmmirror.com"
    fi
    echo "export PATH=\"$TOOLS/flutter/bin:$TOOLS/go/bin:$TOOLS/node/bin:\$HOME/go/bin:\$PATH\""
  } >"$ENV_FILE"
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    if [ -f "$rc" ] || [ "$rc" = "$HOME/.bashrc" ]; then
      grep -q 'loopland_env' "$rc" 2>/dev/null || echo '[ -f "$HOME/.loopland_env" ] && . "$HOME/.loopland_env"' >>"$rc"
    fi
  done
  # shellcheck disable=SC1090
  . "$ENV_FILE"
}

fetch() { curl -fL --retry 3 --connect-timeout 20 "$@"; }

# ---------------------------------------------------------------- 1. 系统工具
step_base() {
  say "基础工具（git、curl、unzip、xz）"
  local miss=()
  for t in git curl unzip xz; do have "$t" || miss+=("$t"); done
  [ ${#miss[@]} -eq 0 ] && { info "已齐全"; return; }
  if [ "$OS" = Darwin ]; then
    have brew || die "需要 Homebrew：https://brew.sh （国内可用 https://gitee.com/cunkai/HomebrewCN）"
    brew install git curl unzip xz
  elif have apt-get; then
    $SUDO apt-get update -y && $SUDO apt-get install -y git curl unzip xz-utils ca-certificates
  else
    die "请先手动安装：${miss[*]}"
  fi
}

# ---------------------------------------------------------------- 2. 镜像
step_mirrors() {
  if [ "$NO_MIRROR" = 1 ]; then say "跳过国内镜像（--no-mirror）"; else
    say "配置国内镜像（写入 $ENV_FILE）"
    info "Flutter：pub.flutter-io.cn / storage.flutter-io.cn；Go：goproxy.cn；npm / pnpm：registry.npmmirror.com"
  fi
  write_env
}

# ---------------------------------------------------------------- 3. Go / Node / pnpm / Flutter
step_go() {
  say "Go（需要 ≥ $NEED_GO）"
  local v=""
  have go && v="$(go version 2>/dev/null | sed -E 's/.*go([0-9]+\.[0-9]+).*/\1/' || true)"
  if [ -n "$v" ] && ver_ge "$v" "$NEED_GO"; then info "已安装 Go $v"; return; fi
  [ -n "$v" ] && info "Go $v 太旧，安装新版到 $TOOLS/go"
  local base="https://go.dev/dl"; [ "$NO_MIRROR" = 0 ] && base="https://golang.google.cn/dl"
  local file
  file="$(fetch -s "$base/?mode=json" | grep -o "\"filename\": *\"go[0-9.]*\.$GOOS-$GOARCH\.tar\.gz\"" | head -n1 | sed -E 's/.*"(go[^"]*)"/\1/')"
  [ -n "$file" ] || die "查不到 Go 安装包，请从 $base 手动下载"
  info "下载 $file"
  mkdir -p "$TOOLS" && rm -rf "$TOOLS/go"
  fetch -o "/tmp/$file" "$base/$file" && tar -C "$TOOLS" -xzf "/tmp/$file" && rm -f "/tmp/$file"
  hash -r
  info "$("$TOOLS/go/bin/go" version)"
}

step_node() {
  say "Node.js（需要 $NEED_NODE 或更新）和 pnpm $PNPM_VERSION"
  local v=""
  have node && v="$(node -v 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/' || true)"
  if [ -z "$v" ] || [ "$v" -lt "$NEED_NODE" ]; then
    local base="https://nodejs.org/dist"; [ "$NO_MIRROR" = 0 ] && base="https://npmmirror.com/mirrors/node"
    local file
    file="$(fetch -s "$base/latest-v$NEED_NODE.x/SHASUMS256.txt" | grep -o "node-v[0-9.]*-$NODEOS-$NODEARCH\.tar\.xz" | head -n1)"
    [ -n "$file" ] || die "查不到 Node.js 安装包，请从 $base 手动下载"
    info "下载 $file"
    rm -rf "$TOOLS/node" && mkdir -p "$TOOLS/node"
    fetch -o "/tmp/$file" "$base/latest-v$NEED_NODE.x/$file" && tar -C "$TOOLS/node" --strip-components=1 -xJf "/tmp/$file" && rm -f "/tmp/$file"
    hash -r
  fi
  info "Node.js $(node -v)"
  [ "$NO_MIRROR" = 0 ] && npm config set registry https://registry.npmmirror.com >/dev/null
  if have pnpm && [ "$(pnpm -v 2>/dev/null || true)" = "$PNPM_VERSION" ]; then info "pnpm $PNPM_VERSION"; return; fi
  info "安装 pnpm@$PNPM_VERSION"
  if [ -w "$(npm prefix -g)" ]; then npm install -g "pnpm@$PNPM_VERSION"; else $SUDO npm install -g "pnpm@$PNPM_VERSION"; fi
  hash -r
  [ "$NO_MIRROR" = 0 ] && pnpm config set registry https://registry.npmmirror.com >/dev/null
  info "pnpm $(pnpm -v)"
}

step_flutter() {
  say "Flutter（需要 ≥ $NEED_FLUTTER）"
  local v=""
  # 不运行 flutter 判断版本（第一次运行要编译工具、旧进程可能占着锁）：读 SDK 里的文件或 git 标签
  local root=""
  have flutter && root="$(cd "$(dirname "$(command -v flutter)")/.." && pwd)"
  if [ -n "$root" ]; then
    if [ -f "$root/bin/cache/flutter.version.json" ]; then
      v="$(sed -nE 's/.*"frameworkVersion": *"([0-9]+\.[0-9]+).*/\1/p' "$root/bin/cache/flutter.version.json" | head -n1)"
    fi
    [ -z "$v" ] && v="$(git -C "$root" describe --tags --abbrev=0 2>/dev/null | sed -nE 's/^([0-9]+\.[0-9]+).*/\1/p' || true)"
  fi
  if [ -n "$v" ] && ver_ge "$v" "$NEED_FLUTTER"; then info "已安装 Flutter $v"; flutter_config; return; fi
  local base="https://storage.googleapis.com"; [ "$NO_MIRROR" = 0 ] && base="https://storage.flutter-io.cn"
  local os=linux; [ "$OS" = Darwin ] && os=macos
  local json
  json="$(fetch -s "$base/flutter_infra_release/releases/releases_$os.json")"
  # 取 3.50.x 的稳定版（macOS 还要匹配 CPU 架构）；没有就取当前稳定版
  local archive
  archive="$(printf '%s' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin); want = sys.argv[1]; arch = sys.argv[2]
ok = lambda r: r["channel"] == "stable" and (r.get("dart_sdk_arch") in (None, arch))
rs = [r for r in d["releases"] if ok(r) and r["version"].startswith(want + ".")] or \
     [r for r in d["releases"] if ok(r) and r["hash"] == d["current_release"]["stable"]]
print(rs[0]["archive"] + " " + rs[0]["sha256"] if rs else "")
' "$NEED_FLUTTER" "$([ "$GOARCH" = arm64 ] && echo arm64 || echo x64)")"
  [ -n "$archive" ] || die "没有找到可用的 Flutter 稳定版"
  local file="${archive%% *}" sum="${archive##* }"
  local url="$base/flutter_infra_release/releases/$file" tmp="/tmp/$(basename "$file")"
  info "下载 Flutter（约 1 GB）：$url"
  fetch -C - -o "$tmp" "$url"
  if have sha256sum; then echo "$sum  $tmp" | sha256sum -c --quiet - || { rm -f "$tmp"; die "Flutter 安装包校验失败，请重新运行"; }; fi
  mkdir -p "$TOOLS"
  [ -d "$TOOLS/flutter" ] && { warn "$TOOLS/flutter 版本不够，改名为 flutter.old"; rm -rf "$TOOLS/flutter.old"; mv "$TOOLS/flutter" "$TOOLS/flutter.old"; }
  case "$tmp" in *.zip) unzip -q "$tmp" -d "$TOOLS" ;; *) tar -C "$TOOLS" -xJf "$tmp" ;; esac
  rm -f "$tmp"
  git config --global --add safe.directory "$TOOLS/flutter" || true
  hash -r
  flutter_config
}
flutter_config() {
  local root; root="$(cd "$(dirname "$(command -v flutter)")/.." && pwd)"
  # 之前没跑完的 flutter 命令会占着 bin/cache/lockfile，新命令会一直等它
  if pgrep -f "$root/bin/cache/dart-sdk" >/dev/null 2>&1; then
    warn "结束之前没退出的 Flutter 进程"
    pkill -f "$root/bin/cache/dart-sdk" || true
    sleep 1
  fi
  rm -f "$root/bin/cache/lockfile"
  info "运行 flutter --version（第一次要编译 Flutter 工具并下载 Dart SDK，可能要几分钟）…"
  flutter --version
  flutter config --no-analytics >/dev/null 2>&1 || true
  dart --disable-analytics >/dev/null 2>&1 || true
  info "下载 Flutter 运行需要的文件（第一次要几分钟）…"
  flutter precache
}

step_docker() {
  if [ "$NO_DOCKER" = 1 ]; then say "跳过 Docker（--no-docker：使用本机 PostgreSQL + Redis）"; return; fi
  say "Docker（运行 PostgreSQL+PostGIS 和 Redis）"
  if ! have docker; then
    if [ "$OS" = Darwin ]; then
      brew install --cask docker
      open -a Docker || true
    elif have apt-get; then
      $SUDO apt-get install -y docker.io docker-compose-v2 || $SUDO apt-get install -y docker.io docker-compose-plugin
      $SUDO usermod -aG docker "$USER" || true
      $SUDO systemctl enable --now docker || true
      warn "已把你加入 docker 组：重新登录（或运行 newgrp docker）后不用 sudo 也能用 docker"
    else
      die "请先安装 Docker（https://docs.docker.com/engine/install/），或加 --no-docker 使用本机数据库"
    fi
  fi
  for _ in $(seq 1 60); do docker info >/dev/null 2>&1 && { info "Docker 正在运行"; return; }; sleep 3; done
  die "Docker 没有运行：Linux 运行 sudo systemctl start docker，macOS 打开 Docker Desktop，然后重新运行本脚本；或加 --no-docker"
}

# ---------------------------------------------------------------- 4. 项目依赖
step_project() {
  say "后端依赖（go mod download）"
  (cd "$ROOT/server" && go mod download)
  say "管理端依赖（pnpm install）"
  (cd "$ROOT/admin" && CI=true pnpm install --frozen-lockfile)
  say "App 依赖（flutter pub get）和配置文件"
  (cd "$ROOT/app" && flutter pub get && dart run tool/gen_config.dart --profile dev)
}

# ---------------------------------------------------------------- 5. 启动
step_start() {
  local dev="$ROOT/scripts/dev.sh"
  if [ "$NO_DOCKER" = 1 ]; then
    say "初始化本机数据库（db-init）"
    "$dev" db-init
  else
    "$dev" deps
  fi
  say "后台启动后端（日志：server/api.log）"
  (cd "$ROOT/server" && nohup go run . >api.log 2>&1 &)
  say "灌演示数据（会等后端启动）"
  "$dev" seed
  if [ -n "$APP_DEVICE" ]; then
    say "后台启动 App（$APP_DEVICE，日志：app/run.log）"
    (cd "$ROOT" && nohup "$dev" app "$APP_DEVICE" >app/run.log 2>&1 &)
  fi
  say "启动管理端：浏览器打开 http://localhost:5173 （账号 admin / admin-password-1）"
  info "App 演示账号：手机号 13800000001–13800000006，验证码 000000"
  info "Ctrl+C 停止管理端；停止后端：pkill -f 'go run .' 或关掉对应进程"
  "$dev" admin
}

echo "圈圈 Loopland · 一键安装与启动"
echo "项目目录：$ROOT    工具目录：$TOOLS"
step_base
step_mirrors
step_go
[ "$NO_MIRROR" = 0 ] && go env -w GOPROXY=https://goproxy.cn,direct
step_node
step_flutter
step_docker
step_project
say "环境检查"
"$ROOT/scripts/dev.sh" check || true
if [ "$NO_START" = 1 ]; then
  say "全部装好了。新开终端（或运行 . ~/.loopland_env）后，以后启动用：scripts/dev.sh all"
  exit 0
fi
step_start

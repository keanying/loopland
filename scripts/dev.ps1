<#
圈圈 Loopland 本地开发脚本（Windows PowerShell 5.1 / PowerShell 7）。Linux/macOS 请用 scripts/dev.sh。

  .\scripts\dev.ps1 check        检查 Go / Node / Flutter / Docker / psql 是否装好
  .\scripts\dev.ps1 deps         用 Docker Desktop 启动 PostgreSQL+PostGIS 和 Redis
  .\scripts\dev.ps1 db-init      不用 Docker 时：在本机 PostgreSQL 里建用户、库和 PostGIS
  .\scripts\dev.ps1 api          启动后端（dev 模式，:8080）
  .\scripts\dev.ps1 seed         灌演示数据（后端需已启动）
  .\scripts\dev.ps1 admin        启动管理端（:5173，代理到后端）
  .\scripts\dev.ps1 admin-mock   启动管理端的离线模拟数据模式（不需要后端）
  .\scripts\dev.ps1 app [设备]   启动 App（flutter run；设备可省略，如 chrome、windows、emulator-5554）
  .\scripts\dev.ps1 doctor       检查后端配置和各第三方服务
  .\scripts\dev.ps1 test         跑后端、管理端、App 全部测试
  .\scripts\dev.ps1 all          deps + api（新窗口）+ seed + admin

第一次运行如果提示「禁止运行脚本」，先执行：
  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
#>
param(
    [Parameter(Position = 0)][string]$Command = '',
    [Parameter(Position = 1)][string]$Device = ''
)
$ErrorActionPreference = 'Stop'
# 中文输出：Windows PowerShell 5.1 默认用系统代码页
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$Root = Split-Path -Parent $PSScriptRoot
$ApiPort = if ($env:LOOPLAND_API_PORT) { $env:LOOPLAND_API_PORT } else { '8080' }
function Set-Default($name, $value) {
    if (-not [Environment]::GetEnvironmentVariable($name, 'Process')) { [Environment]::SetEnvironmentVariable($name, $value, 'Process') }
}
Set-Default 'LOOPLAND_ENV' 'dev'
Set-Default 'LOOPLAND_HTTP_ADDR' ":$ApiPort"
Set-Default 'LOOPLAND_DATABASE_URL' 'postgres://loopland:loopland@localhost:5432/loopland?sslmode=disable'
Set-Default 'LOOPLAND_REDIS_URL' 'redis://localhost:6379/0'
Set-Default 'LOOPLAND_BOOTSTRAP_ADMIN' 'admin:admin-password-1'

function Say($msg) { Write-Host "==> $msg" -ForegroundColor Green }
function Die($msg) { Write-Host "错误：$msg" -ForegroundColor Red; exit 1 }
function Have($tool) { [bool](Get-Command $tool -ErrorAction SilentlyContinue) }
# 安静地运行外部命令并拿到退出码和输出：Windows PowerShell 5.1 在
# $ErrorActionPreference = 'Stop' 时会把被重定向的 stderr 当成终止错误。
function Invoke-Quiet {
    param([string]$Exe, [string[]]$Arguments)
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $Exe @Arguments 2>&1 | ForEach-Object { "$_" }
        return [pscustomobject]@{ Code = $LASTEXITCODE; Output = @($out) }
    } catch {
        return [pscustomobject]@{ Code = 1; Output = @("$_") }
    } finally {
        $ErrorActionPreference = $old
    }
}
function Invoke-Checked {
    param([string]$Exe, [string[]]$Arguments)
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { Die "$Exe $($Arguments -join ' ') 失败（退出码 $LASTEXITCODE）" }
}

function Compose {
    param([string[]]$Arguments)
    $file = Join-Path $Root 'deploy/docker-compose.yml'
    if (Have 'docker') {
        if ((Invoke-Quiet 'docker' @('compose', 'version')).Code -eq 0) { Invoke-Checked 'docker' (@('compose', '-f', $file) + $Arguments); return }
    }
    if (Have 'docker-compose') { Invoke-Checked 'docker-compose' (@('-f', $file) + $Arguments); return }
    Die '没有找到 Docker。安装 Docker Desktop（需要 WSL2），或者自己装 PostgreSQL 16 + PostGIS 和 Redis（Memurai 或 WSL 里的 redis-server）后运行 db-init'
}

function Wait-Api {
    for ($i = 0; $i -lt 60; $i++) {
        try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 "http://localhost:$ApiPort/healthz" | Out-Null; return } catch { Start-Sleep -Seconds 1 }
    }
    Die '后端 60 秒内没有启动，看看后端窗口里的日志'
}

function Cmd-Check {
    foreach ($t in 'go', 'node', 'pnpm', 'flutter', 'docker', 'psql') {
        if (Have $t) {
            # go 用 `go version`，其他工具用 --version
            $flag = if ($t -eq 'go') { @('version') } else { @('--version') }
            $r = Invoke-Quiet $t $flag
            $v = ($r.Output | Where-Object { $_.Trim() } | Select-Object -First 1)
            if ($r.Code -eq 0) {
                Write-Host ("  ✓ {0,-8} {1}" -f $t, $v)
            } else {
                Write-Host ("  ! {0,-8} 已安装，但运行出错：{1}" -f $t, $v) -ForegroundColor Yellow
            }
        } else {
            Write-Host ("  ✗ {0,-8} 未安装" -f $t)
        }
    }
    Write-Host ''
    Write-Host '需要：Go ≥ 1.26（后端）、Node 22（管理端）、Flutter 3.50（App）；数据库用 Docker Desktop，或本机 PostgreSQL 16 + PostGIS 3 + Redis 7。'
}

function Cmd-Deps {
    Say '启动 PostgreSQL+PostGIS 和 Redis（Docker）'
    Compose @('up', '-d', 'postgres', 'redis')
    Say '等待数据库就绪'
    for ($i = 0; $i -lt 60; $i++) {
        $r = Invoke-Quiet 'docker' @('compose', '-f', (Join-Path $Root 'deploy/docker-compose.yml'), 'exec', '-T', 'postgres', 'pg_isready', '-U', 'loopland')
        if ($r.Code -eq 0) { Say '数据库就绪'; return }
        Start-Sleep -Seconds 1
    }
    Die '数据库 60 秒内没有就绪'
}

function Cmd-DbInit {
    if (-not (Have 'psql')) { Die '需要 psql（随 PostgreSQL 安装，在 C:\Program Files\PostgreSQL\16\bin）' }
    $su = if ($env:PGSUPERUSER) { $env:PGSUPERUSER } else { 'postgres' }
    $pgHost = if ($env:PGHOST) { $env:PGHOST } else { 'localhost' }
    Say "用超级用户 $su 创建 loopland 用户、loopland 库和 PostGIS 扩展（已存在则跳过）"
    $sql = @'
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='loopland') THEN CREATE ROLE loopland LOGIN PASSWORD 'loopland' CREATEDB; END IF;
END $$;
SELECT 'CREATE DATABASE loopland OWNER loopland' WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname='loopland')\gexec
'@
    $tmp = New-TemporaryFile
    Set-Content -Path $tmp -Value $sql -Encoding UTF8
    Invoke-Checked 'psql' @('-U', $su, '-h', $pgHost, '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-f', $tmp.FullName)
    Remove-Item $tmp
    Invoke-Checked 'psql' @('-U', $su, '-h', $pgHost, '-d', 'loopland', '-v', 'ON_ERROR_STOP=1', '-c', 'CREATE EXTENSION IF NOT EXISTS postgis')
    Say '完成。后端启动时会自动建表。'
}

function Cmd-Api {
    Say "启动后端 http://localhost:$ApiPort （管理员 $(($env:LOOPLAND_BOOTSTRAP_ADMIN -split ':')[0])）"
    Set-Location (Join-Path $Root 'server')
    Invoke-Checked 'go' @('run', '.')
}

function Cmd-Seed {
    Wait-Api
    Say '灌演示数据'
    Set-Location (Join-Path $Root 'server')
    Invoke-Checked 'go' @('run', '.', 'seed', '-api', "http://localhost:$ApiPort", '-admin', $env:LOOPLAND_BOOTSTRAP_ADMIN)
}

function Npm-Ready {
    Set-Location (Join-Path $Root 'admin')
    if (-not (Test-Path 'node_modules')) { Say '安装管理端依赖'; Invoke-Checked 'pnpm' @('install', '--frozen-lockfile') }
}

function Cmd-Admin {
    Npm-Ready
    Say '启动管理端（端口、后端地址等见 admin\config.yaml，本机覆盖写 admin\config.local.yaml）'
    Invoke-Checked 'pnpm' @('run', 'dev')
}

function Cmd-AdminMock {
    Npm-Ready
    Say '启动管理端（模拟数据，不需要后端）http://localhost:5173'
    Invoke-Checked 'pnpm' @('run', 'dev:mock')
}

function Cmd-App {
    Set-Location (Join-Path $Root 'app')
    Invoke-Checked 'flutter' @('pub', 'get')
    $appProfile = if ($env:LOOPLAND_APP_PROFILE) { $env:LOOPLAND_APP_PROFILE } else { 'dev' }
    # 配置统一在 app\config\app.yaml（本机覆盖写 app.local.yaml），这里生成各端用的配置文件。
    $genArgs = @('run', 'tool/gen_config.dart', '--profile', $appProfile)
    if ($Device -like 'emulator-*' -and -not (Test-Path 'config/app.local.yaml')) {
        # Android 模拟器访问电脑上的后端要用 10.0.2.2
        $genArgs += @('--api-base', "http://10.0.2.2:$ApiPort")
    }
    Invoke-Checked 'dart' $genArgs
    $flutterArgs = @('run', "--dart-define-from-file=config/$appProfile.json")
    if ($Device) { $flutterArgs += @('-d', $Device) }
    Invoke-Checked 'flutter' $flutterArgs
}

function Cmd-Doctor {
    Set-Location (Join-Path $Root 'server')
    Invoke-Checked 'go' @('run', '.', 'doctor')
}

function Cmd-Test {
    Say '后端测试（需要 PostgreSQL 和 Redis）'
    Set-Location (Join-Path $Root 'server')
    Invoke-Checked 'go' @('vet', './...')
    Invoke-Checked 'go' @('test', './...')
    Say '管理端检查'
    Npm-Ready
    Invoke-Checked 'pnpm' @('run', 'lint')
    Invoke-Checked 'pnpm' @('run', 'build')
    if (Have 'flutter') {
        Say 'App 检查'
        Set-Location (Join-Path $Root 'app')
        Invoke-Checked 'flutter' @('pub', 'get')
        Invoke-Checked 'flutter' @('analyze')
        Invoke-Checked 'flutter' @('test')
    } else {
        Write-Host '未安装 Flutter，跳过 App'
    }
}

function Cmd-All {
    Cmd-Deps
    Say '在新窗口启动后端'
    $shell = if (Have 'pwsh') { 'pwsh' } else { 'powershell' }
    Start-Process $shell -ArgumentList @('-NoExit', '-File', (Join-Path $PSScriptRoot 'dev.ps1'), 'api')
    Cmd-Seed
    Cmd-Admin
}

switch ($Command) {
    'check' { Cmd-Check }
    'deps' { Cmd-Deps }
    'db-init' { Cmd-DbInit }
    'api' { Cmd-Api }
    'seed' { Cmd-Seed }
    'admin' { Cmd-Admin }
    'admin-mock' { Cmd-AdminMock }
    'app' { Cmd-App }
    'doctor' { Cmd-Doctor }
    'test' { Cmd-Test }
    'all' { Cmd-All }
    default { Get-Help $MyInvocation.MyCommand.Path; (Get-Content $PSCommandPath -TotalCount 17 | Select-Object -Skip 1) | ForEach-Object { Write-Host $_ }; exit 1 }
}

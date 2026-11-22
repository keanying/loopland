<#
圈圈 Loopland 一键安装与启动（Windows 10/11，PowerShell 5.1 / 7）。Linux/macOS 用 scripts/setup.sh。

从零开始：装工具 → 配国内镜像 → 装项目依赖 → 启动数据库 → 启动后端、灌演示数据、启动管理端。
可以重复运行：已经装好的会跳过。

  .\scripts\setup.ps1                     全部做完并启动
  .\scripts\setup.ps1 -NoStart            只装环境和依赖，不启动
  .\scripts\setup.ps1 -NoDocker           不用 Docker：用本机 PostgreSQL(PostGIS) + Redis（会运行 db-init）
  .\scripts\setup.ps1 -NoMirror           不配置国内镜像（海外网络）
  .\scripts\setup.ps1 -WithAndroid        顺带安装 Android Studio（开发安卓 App 需要）
  .\scripts\setup.ps1 -App chrome         最后再启动 App（chrome / windows / emulator-5554 …）
  .\scripts\setup.ps1 -ToolsDir D:\dev    Flutter SDK 装在哪个目录下（默认 D:\dev，没有 D 盘就用 用户目录\dev）
  .\scripts\setup.ps1 -FlutterMirror https://mirrors.tuna.tsinghua.edu.cn/flutter
                                          指定 Flutter 下载镜像（默认自动测速，选最快的）
下载中断（Ctrl+C 或断网）后重新运行会接着下载，不会从头开始。

第一次运行如果提示「禁止运行脚本」，先执行：
  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
安装软件时 Windows 可能弹出管理员确认（UAC），点「是」即可。
#>
param(
    [switch]$NoStart,
    [switch]$NoDocker,
    [switch]$NoMirror,
    [switch]$WithAndroid,
    [string]$App = '',
    [string]$ToolsDir = '',
    [string]$FlutterMirror = ''
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest 的进度条在 5.1 里会让下载慢很多
# 老版本 Windows PowerShell 5.1 默认不启用 TLS 1.2，下载会失败
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$Root = Split-Path -Parent $PSScriptRoot
$NeedGo = [version]'1.26'
$NeedNode = 22
$NeedFlutter = [version]'3.50'
$PnpmVersion = '10.28.0'
if (-not $ToolsDir) { $ToolsDir = if (Test-Path 'D:\') { 'D:\dev' } else { Join-Path $HOME 'dev' } }

function Say($msg) { Write-Host "`n==> $msg" -ForegroundColor Green }
function Info($msg) { Write-Host "    $msg" }
function Warn($msg) { Write-Host "    ! $msg" -ForegroundColor Yellow }
function Die($msg) { Write-Host "`n错误：$msg" -ForegroundColor Red; exit 1 }
function Have($tool) { [bool](Get-Command $tool -ErrorAction SilentlyContinue) }

# 运行外部命令并拿到输出和退出码（不让 stderr 在 5.1 里变成终止错误）
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
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Exe @Arguments } finally { $ErrorActionPreference = $old }
    if ($LASTEXITCODE -ne 0) { Die "$Exe $($Arguments -join ' ') 失败（退出码 $LASTEXITCODE）" }
}

# 安装软件后，把系统和用户的 PATH 重新读进当前窗口
function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = ($machine, $user | Where-Object { $_ }) -join ';'
}
function Set-UserEnv($name, $value) {
    [Environment]::SetEnvironmentVariable($name, $value, 'User')
    [Environment]::SetEnvironmentVariable($name, $value, 'Process')
}
function Add-UserPath($dir) {
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @($user -split ';' | Where-Object { $_ })
    if ($parts -notcontains $dir) {
        [Environment]::SetEnvironmentVariable('Path', (@($dir) + $parts) -join ';', 'User')
    }
    Update-SessionPath
}

function Get-Version([string]$exe, [string[]]$arguments, [string]$pattern) {
    if (-not (Have $exe)) { return $null }
    $r = Invoke-Quiet $exe $arguments
    foreach ($line in $r.Output) {
        if ($line -match $pattern) { return [version]"$($Matches[1]).$($Matches[2])" }
    }
    return $null
}

function Winget-Install([string]$id, [string]$name) {
    if (-not (Have 'winget')) {
        Die "没有 winget（Windows 10 需要在微软商店安装「应用安装程序 App Installer」）。也可以手动安装 $name 后重新运行本脚本。"
    }
    Info "用 winget 安装 $name（$id）…"
    $r = Invoke-Quiet 'winget' @('install', '--id', $id, '-e', '--source', 'winget', '--accept-package-agreements', '--accept-source-agreements', '--silent')
    # 0 = 成功；-1978335189 = 已是最新；-1978335135 = 已安装
    if ($r.Code -ne 0 -and $r.Code -ne -1978335189 -and $r.Code -ne -1978335135) {
        $r.Output | Select-Object -Last 5 | ForEach-Object { Info $_ }
        Die "安装 $name 失败（winget 退出码 $($r.Code)）。可以手动安装后重新运行本脚本。"
    }
    Update-SessionPath
}

# ---------------------------------------------------------------- 1. 镜像
function Step-Mirrors {
    if ($NoMirror) { Say '跳过国内镜像（-NoMirror）'; return }
    Say '配置国内镜像（写入当前用户的环境变量）'
    Set-UserEnv 'PUB_HOSTED_URL' 'https://pub.flutter-io.cn'
    Set-UserEnv 'FLUTTER_STORAGE_BASE_URL' 'https://storage.flutter-io.cn'
    Set-UserEnv 'GOPROXY' 'https://goproxy.cn,direct'
    Set-UserEnv 'COREPACK_NPM_REGISTRY' 'https://registry.npmmirror.com'
    Info 'Flutter：pub.flutter-io.cn / storage.flutter-io.cn；Go：goproxy.cn；npm / pnpm：registry.npmmirror.com'
}

# ---------------------------------------------------------------- 2. 工具
function Step-Git {
    Say 'Git'
    if (Have 'git') { Info ((Invoke-Quiet 'git' @('--version')).Output | Select-Object -First 1); return }
    Winget-Install 'Git.Git' 'Git'
    if (-not (Have 'git')) { Die '装好了 Git，但当前窗口还找不到 git：关掉 PowerShell 重新打开后再运行本脚本。' }
}

function Step-Go {
    Say "Go（需要 ≥ $NeedGo）"
    $v = Get-Version 'go' @('version') 'go(\d+)\.(\d+)'
    if ($v -and $v -ge $NeedGo) { Info "已安装 Go $v"; return }
    if ($v) { Info "Go $v 太旧，升级…" }
    Winget-Install 'GoLang.Go' 'Go'
    $v = Get-Version 'go' @('version') 'go(\d+)\.(\d+)'
    if (-not $v -or $v -lt $NeedGo) { Die "Go 版本仍然不够（当前 $v）。请从 https://golang.google.cn/dl/ 下载最新版安装后重新运行。" }
    Info "Go $v"
}

function Step-Node {
    Say "Node.js（需要 $NeedNode 或更新）和 pnpm $PnpmVersion"
    $v = Get-Version 'node' @('-v') 'v(\d+)\.(\d+)'
    if (-not $v -or $v.Major -lt $NeedNode) {
        $r = Invoke-Quiet 'winget' @('show', '--id', "OpenJS.NodeJS.$NeedNode", '-e', '--source', 'winget')
        if ($r.Code -eq 0) { Winget-Install "OpenJS.NodeJS.$NeedNode" "Node.js $NeedNode" } else { Winget-Install 'OpenJS.NodeJS.LTS' 'Node.js LTS' }
        $v = Get-Version 'node' @('-v') 'v(\d+)\.(\d+)'
        if (-not $v -or $v.Major -lt $NeedNode) { Die '装好了 Node.js，但当前窗口还找不到：关掉 PowerShell 重新打开后再运行本脚本。' }
    }
    Info "Node.js $v"
    if (-not $NoMirror) { Invoke-Quiet 'npm' @('config', 'set', 'registry', 'https://registry.npmmirror.com') | Out-Null }
    $pv = (Invoke-Quiet 'pnpm' @('-v')).Output | Select-Object -First 1
    if ((Have 'pnpm') -and $pv -eq $PnpmVersion) { Info "pnpm $pv"; return }
    # npm 全局安装到 %AppData%\npm，不需要管理员权限（corepack enable 要写 Program Files）
    Info "安装 pnpm@$PnpmVersion…"
    Invoke-Checked 'npm' @('install', '-g', "pnpm@$PnpmVersion")
    Add-UserPath (Join-Path $env:APPDATA 'npm')
    if (-not (Have 'pnpm')) { Die "pnpm 装好了但找不到：确认 $env:APPDATA\npm 在 PATH 里，重新打开 PowerShell 后再运行。" }
    if (-not $NoMirror) { Invoke-Quiet 'pnpm' @('config', 'set', 'registry', 'https://registry.npmmirror.com') | Out-Null }
}

# Flutter 下载镜像：先各下 2 MB 测速，选最快的（同一个文件，断点续传可以换镜像接着下）
$FlutterMirrors = @(
    'https://storage.flutter-io.cn',
    'https://mirrors.tuna.tsinghua.edu.cn/flutter',
    'https://mirrors.ustc.edu.cn/flutter',
    'https://mirrors.cernet.edu.cn/flutter',
    'https://storage.googleapis.com'
)
function Measure-Mirror([string]$url) {
    if (-not (Have 'curl.exe')) { return 0 }
    $r = Invoke-Quiet 'curl.exe' @('-sL', '--fail', '-r', '0-2097151', '--connect-timeout', '5', '--max-time', '10', '-o', 'NUL', '-w', '%{speed_download}', $url)
    $speed = 0.0
    $text = "$($r.Output | Select-Object -Last 1)".Trim()
    if ($r.Code -eq 0 -and [double]::TryParse($text, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$speed)) { return $speed }
    return 0
}
function Select-FlutterMirror([string]$archive) {
    if ($FlutterMirror) { return $FlutterMirror.TrimEnd('/') }
    $list = if ($NoMirror) { @('https://storage.googleapis.com') } else { $FlutterMirrors }
    if ($list.Count -eq 1) { return $list[0] }
    Info '测试各个 Flutter 镜像的下载速度…'
    $best = $null; $bestSpeed = 0
    foreach ($m in $list) {
        $speed = Measure-Mirror "$m/flutter_infra_release/releases/$archive"
        Info ("  {0,-48} {1}" -f $m, $(if ($speed -gt 0) { '{0:N0} KB/s' -f ($speed / 1KB) } else { '连不上' }))
        if ($speed -gt $bestSpeed) { $best = $m; $bestSpeed = $speed }
    }
    if (-not $best) { Die '所有 Flutter 镜像都连不上，请检查网络（或用 -FlutterMirror 指定一个可用的地址）。' }
    if ($bestSpeed -lt 200KB) { Warn ('最快的镜像也只有 {0:N0} KB/s，下载会比较久；可以换个网络（如手机热点）后重新运行，会接着下载。' -f ($bestSpeed / 1KB)) }
    return $best
}

function Step-Flutter {
    Say "Flutter（需要 ≥ $NeedFlutter）"
    # 不运行 flutter 命令判断版本：第一次运行要编译工具，旧进程还可能占着锁，看起来像卡死
    $v = Get-FlutterVersion
    $oldRoot = Get-FlutterRoot
    if ($v -and $v -ge $NeedFlutter) { Info "已安装 Flutter $v（$oldRoot）"; Step-FlutterConfig; return }
    if ($v) { Info "Flutter $v（$oldRoot）版本不够，安装 $NeedFlutter" }
    Info '查询 Flutter 版本列表…'
    $rel = $null
    $jsonBases = if ($NoMirror) { @('https://storage.googleapis.com') } else { $FlutterMirrors }
    foreach ($jb in $jsonBases) {
        try { $rel = Invoke-RestMethod -TimeoutSec 20 "$jb/flutter_infra_release/releases/releases_windows.json"; break } catch { $rel = $null }
    }
    if (-not $rel) { Die '查不到 Flutter 版本列表，请检查网络。' }
    $pick = $rel.releases | Where-Object { $_.channel -eq 'stable' -and $_.version -like "$($NeedFlutter.Major).$($NeedFlutter.Minor).*" } | Select-Object -First 1
    if (-not $pick) { $pick = $rel.releases | Where-Object { $_.hash -eq $rel.current_release.stable } | Select-Object -First 1 }
    if (-not $pick) { Die '没有找到可用的 Flutter 稳定版' }
    $mirror = Select-FlutterMirror $pick.archive
    if (-not $NoMirror) { Set-UserEnv 'FLUTTER_STORAGE_BASE_URL' $mirror }   # 之后 Flutter 下载引擎文件也走这个镜像
    $dest = Join-Path $ToolsDir 'flutter'
    $zip = Join-Path $env:TEMP ([IO.Path]::GetFileName($pick.archive))
    $url = "$mirror/flutter_infra_release/releases/$($pick.archive)"
    Info "下载 Flutter $($pick.version)（约 1.8 GB）：$url"
    Info "中断后重新运行会接着下载（临时文件：$zip）"
    if (Have 'curl.exe') { Invoke-Checked 'curl.exe' @('-L', '--fail', '--retry', '5', '--retry-delay', '3', '-C', '-', '-o', $zip, $url) } else { Invoke-WebRequest $url -OutFile $zip }
    if ($pick.sha256) {
        Info '校验文件…'
        $hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
        if ($hash -ne $pick.sha256.ToLower()) { Remove-Item $zip -Force; Die 'Flutter 安装包校验失败（下载不完整或镜像文件有误），已删除，请重新运行。' }
    }
    if (Test-Path (Join-Path $dest 'bin\flutter.bat')) {
        Warn "$dest 已存在但版本不够，改名为 flutter.old"
        $old = "$dest.old"
        if (Test-Path $old) { Remove-Item $old -Recurse -Force }
        Rename-Item $dest $old
    }
    New-Item -ItemType Directory -Force -Path $ToolsDir | Out-Null
    Info "解压到 $ToolsDir…"
    if (Have 'tar.exe') { Invoke-Checked 'tar.exe' @('-xf', $zip, '-C', $ToolsDir) } else { Expand-Archive $zip -DestinationPath $ToolsDir -Force }
    Remove-Item $zip -Force
    Add-UserPath (Join-Path $dest 'bin')
    # 用户 PATH 排在系统 PATH 后面：旧 Flutter 如果在系统 PATH 里，还会先被找到
    $env:Path = "$(Join-Path $dest 'bin');$env:Path"
    Info "已加入 PATH：$dest\bin"
    if ($oldRoot -and ($oldRoot -ne $dest)) {
        Warn "旧的 Flutter $v 还在 $oldRoot。请在「系统属性 → 环境变量」的 Path 里删掉 $oldRoot\bin，避免 IDE 和新开的终端用到旧版本。"
    }
    Step-FlutterConfig
}
function Get-FlutterRoot {
    $cmd = Get-Command flutter -ErrorAction SilentlyContinue
    if ($cmd) { return Split-Path (Split-Path $cmd.Source) }
    return $null
}
# 从 SDK 里的文件读版本：bin\cache\flutter.version.json（运行过一次后才有），否则 git 标签
function Get-FlutterVersion {
    $root = Get-FlutterRoot
    if (-not $root) { return $null }
    $text = $null
    $json = Join-Path $root 'bin\cache\flutter.version.json'
    if (Test-Path $json) {
        try { $text = (Get-Content $json -Raw | ConvertFrom-Json).frameworkVersion } catch { $text = $null }
    }
    if (-not $text) {
        $r = Invoke-Quiet 'git' @('-C', $root, 'describe', '--tags', '--abbrev=0')
        if ($r.Code -eq 0) { $text = $r.Output | Select-Object -First 1 }
    }
    if ($text -and $text -match '^(\d+)\.(\d+)') { return [version]"$($Matches[1]).$($Matches[2])" }
    return $null
}
# 之前没跑完的 flutter / flutter doctor 会占着 bin\cache\lockfile，新命令会一直等它
# 之前没跑完的 flutter / flutter doctor 会占着锁：Windows 上 flutter.bat 先拿 bin\cache\flutter.bat.lock
# （拿不到就一声不吭地一直等），Dart 工具再拿 bin\cache\lockfile。
function Clear-FlutterLock {
    $root = Get-FlutterRoot
    if (-not $root) { return }
    $procs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            $_.ProcessId -ne $PID -and (
                ($_.ExecutablePath -and $_.ExecutablePath -like "$root\*") -or
                ($_.Name -eq 'cmd.exe' -and $_.CommandLine -and $_.CommandLine -like "*$root\bin\*"))
        })
    if ($procs.Count -gt 0) {
        Warn "结束 $($procs.Count) 个之前没退出的 Flutter 进程（$(($procs | ForEach-Object Name | Sort-Object -Unique) -join '、')；IDE 的 Dart 分析服务会自动重启）"
        $procs | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 2
    }
    foreach ($f in 'flutter.bat.lock', 'lockfile') {
        $lock = Join-Path $root "bin\cache\$f"
        if (Test-Path $lock) {
            Remove-Item $lock -Force -ErrorAction SilentlyContinue
            if (Test-Path $lock) {
                Warn "$lock 还被别的程序占着：请先关掉 GoLand / Android Studio / VS Code 等打开了 Flutter 项目的程序，再重新运行本脚本。"
            }
        }
    }
}

# 运行 flutter，输出直接显示；每分钟提示一次还在运行，超过 $Minutes 分钟就停止并给出排查办法
function Invoke-FlutterWatched([string[]]$Arguments, [int]$Minutes = 20) {
    $bat = Join-Path (Get-FlutterRoot) 'bin\flutter.bat'
    $argLine = '/d /c ""' + $bat + '" ' + ($Arguments -join ' ') + '"'
    $p = Start-Process -FilePath 'cmd.exe' -ArgumentList $argLine -NoNewWindow -PassThru
    $null = $p.Handle   # 先取一次句柄，否则进程结束后 ExitCode 读不到（PowerShell 已知问题）
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $p.WaitForExit(60000)) {
        $m = [int]$sw.Elapsed.TotalMinutes
        if ($m -ge $Minutes) {
            Get-CimInstance Win32_Process -Filter "ParentProcessId=$($p.Id)" -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
            Die ("flutter $($Arguments -join ' ') 超过 $Minutes 分钟没有结束，已停止。请在新的 PowerShell 窗口运行下面的命令看卡在哪一步，把最后几行发给开发同学：`n" +
                "    & '$bat' --verbose --version")
        }
        Info "flutter $($Arguments -join ' ') 仍在运行（已 $m 分钟）…第一次会编译 Flutter 工具、下载文件；长时间没有任何新输出时，多半是被 IDE 或旧进程占着锁"
    }
    if ($p.ExitCode -ne 0) { Die "flutter $($Arguments -join ' ') 失败（退出码 $($p.ExitCode)）" }
}

function Step-FlutterConfig {
    Clear-FlutterLock
    Info '运行 flutter --version（第一次要编译 Flutter 工具并下载 Dart SDK，可能要几分钟，下面会显示进度）…'
    Invoke-FlutterWatched @('--version')
    Invoke-Quiet 'flutter' @('config', '--no-analytics') | Out-Null
    Invoke-Quiet 'dart' @('--disable-analytics') | Out-Null
    Info '下载 Flutter 运行需要的文件（第一次要几分钟）…'
    Invoke-FlutterWatched @('precache') 30
}

function Step-Docker {
    if ($NoDocker) { Say '跳过 Docker（-NoDocker：使用本机 PostgreSQL + Redis）'; return }
    Say 'Docker Desktop（运行 PostgreSQL+PostGIS 和 Redis）'
    if (-not (Have 'docker')) {
        Winget-Install 'Docker.DockerDesktop' 'Docker Desktop'
        Warn 'Docker Desktop 第一次安装后通常需要重启电脑，并按提示启用 WSL2。重启后重新运行本脚本即可。'
    }
    if ((Invoke-Quiet 'docker' @('info')).Code -eq 0) { Info 'Docker 正在运行'; return }
    $exe = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
    if (Test-Path $exe) {
        Info '启动 Docker Desktop，等待就绪（最多 3 分钟）…'
        Start-Process $exe
        for ($i = 0; $i -lt 90; $i++) {
            Start-Sleep -Seconds 2
            if ((Invoke-Quiet 'docker' @('info')).Code -eq 0) { Info 'Docker 已就绪'; return }
        }
    }
    Die 'Docker 没有运行。请打开 Docker Desktop，等左下角显示 Engine running 后重新运行本脚本；或者加 -NoDocker 使用本机数据库。'
}

function Step-Android {
    if (-not $WithAndroid) { return }
    Say 'Android Studio'
    if (Test-Path (Join-Path $env:ProgramFiles 'Android\Android Studio')) { Info '已安装' }
    else { Winget-Install 'Google.AndroidStudio' 'Android Studio' }
    Info '第一次打开 Android Studio，按向导装好 Android SDK 和模拟器后，运行：flutter doctor --android-licenses'
}

# ---------------------------------------------------------------- 3. 项目依赖
function Step-ProjectDeps {
    Say '后端依赖（go mod download）'
    Push-Location (Join-Path $Root 'server')
    try { Invoke-Checked 'go' @('mod', 'download') } finally { Pop-Location }

    Say '管理端依赖（pnpm install）'
    Push-Location (Join-Path $Root 'admin')
    # CI=true：非交互运行（node_modules 需要重建时不停下来等确认）
    $env:CI = 'true'
    try { Invoke-Checked 'pnpm' @('install', '--frozen-lockfile') } finally { Remove-Item Env:CI -ErrorAction SilentlyContinue; Pop-Location }

    Say 'App 依赖（flutter pub get）和配置文件'
    Push-Location (Join-Path $Root 'app')
    try {
        Invoke-Checked 'flutter' @('pub', 'get')
        Invoke-Checked 'dart' @('run', 'tool/gen_config.dart', '--profile', 'dev')
    } finally { Pop-Location }
}

# ---------------------------------------------------------------- 4. 启动
function Step-Start {
    $dev = Join-Path $PSScriptRoot 'dev.ps1'
    if ($NoDocker) {
        Say '初始化本机数据库（db-init，会要求输入 PostgreSQL 管理员密码）'
        & $dev db-init
    }
    $shell = if (Have 'pwsh') { 'pwsh' } else { 'powershell' }
    if (-not $NoDocker) {
        Say '启动 PostgreSQL + Redis（Docker）'
        & $dev deps
    }
    Say '在新窗口启动后端（:8080）'
    Start-Process $shell -ArgumentList @('-NoExit', '-ExecutionPolicy', 'Bypass', '-File', $dev, 'api')
    Say '灌演示数据（会等后端启动）'
    & $dev seed
    if ($App) {
        Say "在新窗口启动 App（$App）"
        Start-Process $shell -ArgumentList @('-NoExit', '-ExecutionPolicy', 'Bypass', '-File', $dev, 'app', $App)
    }
    Say '启动管理端：浏览器打开 http://localhost:5173 （账号 admin / admin-password-1）'
    Info 'App 演示账号：手机号 13800000001–13800000006，验证码 000000'
    Info '按 Ctrl+C 停止管理端；后端在另一个窗口里，关掉那个窗口即停止。'
    & $dev admin
}

# ---------------------------------------------------------------- 主流程
Write-Host '圈圈 Loopland · 一键安装与启动' -ForegroundColor Cyan
Write-Host "项目目录：$Root    工具目录：$ToolsDir"
Step-Mirrors
Step-Git
Step-Go
if (-not $NoMirror) { Invoke-Quiet 'go' @('env', '-w', 'GOPROXY=https://goproxy.cn,direct') | Out-Null }
Step-Node
Step-Flutter
Step-Docker
Step-Android
Step-ProjectDeps

Say '环境检查'
& (Join-Path $PSScriptRoot 'dev.ps1') check

if ($NoStart) {
    Say '全部装好了。以后启动：.\scripts\dev.ps1 all（或在 GoLand 里用「后端 API + 演示数据」）'
    exit 0
}
Step-Start

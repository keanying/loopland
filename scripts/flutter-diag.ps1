<#
Flutter 卡住时的诊断脚本（Windows）。运行：
  .\scripts\flutter-diag.ps1
会打印一份摘要，并把详细日志写到 flutter-diag.log（在仓库根目录），把摘要整段发给开发同学即可。
不会修改任何东西（只会结束它自己启动、超时的 flutter 进程）。
#>
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$Log = Join-Path $Root 'flutter-diag.log'
function Line($k, $v) { Write-Host ("{0,-28} {1}" -f $k, $v) }

# 带超时运行，返回 [退出码, 输出]
function Run-Timed([string]$exe, [string]$argLine, [int]$seconds) {
    $out = [IO.Path]::GetTempFileName(); $err = [IO.Path]::GetTempFileName()
    $p = Start-Process -FilePath $exe -ArgumentList $argLine -NoNewWindow -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    $null = $p.Handle
    if (-not $p.WaitForExit($seconds * 1000)) {
        Get-CimInstance Win32_Process -Filter "ParentProcessId=$($p.Id)" -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        $text = (Get-Content $out, $err -ErrorAction SilentlyContinue) -join "`n"
        Remove-Item $out, $err -ErrorAction SilentlyContinue
        return @('超时', $text)
    }
    $text = (Get-Content $out, $err -ErrorAction SilentlyContinue) -join "`n"
    Remove-Item $out, $err -ErrorAction SilentlyContinue
    return @($p.ExitCode, $text)
}

Write-Host '==== Flutter 诊断（把下面这段整个发给开发同学） ====' -ForegroundColor Cyan
$cmd = Get-Command flutter -ErrorAction SilentlyContinue
$froot = if ($cmd) { Split-Path (Split-Path $cmd.Source) } else { $null }
Line 'flutter 命令' $(if ($cmd) { $cmd.Source } else { '找不到（不在 PATH 里）' })
$all = @(Get-Command flutter -All -ErrorAction SilentlyContinue | ForEach-Object Source)
if ($all.Count -gt 1) { Line 'PATH 里有多个 flutter' ($all -join ' | ') }
$dartCmd = Get-Command dart -ErrorAction SilentlyContinue
Line 'dart 命令' $(if ($dartCmd) { $dartCmd.Source } else { '无' })
foreach ($v in 'FLUTTER_STORAGE_BASE_URL', 'PUB_HOSTED_URL', 'FLUTTER_GIT_URL', 'HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY') {
    $val = [Environment]::GetEnvironmentVariable($v)
    if ($val) { Line $v $val }
}
if (-not $froot) { exit 1 }

$cache = Join-Path $froot 'bin\cache'
$checks = [ordered]@{
    'dart-sdk\bin\dart.exe'          = Join-Path $cache 'dart-sdk\bin\dart.exe'
    'flutter_tools.snapshot'         = Join-Path $cache 'flutter_tools.snapshot'
    'flutter_tools.stamp'            = Join-Path $cache 'flutter_tools.stamp'
    'engine-dart-sdk.stamp'          = Join-Path $cache 'engine-dart-sdk.stamp'
    'flutter.version.json'           = Join-Path $cache 'flutter.version.json'
    'flutter.bat.lock'               = Join-Path $cache 'flutter.bat.lock'
    'lockfile'                       = Join-Path $cache 'lockfile'
}
foreach ($k in $checks.Keys) { Line $k $(if (Test-Path $checks[$k]) { '有' } else { '无' }) }
$engine = Join-Path $froot 'bin\internal\engine.version'
$stamp = Join-Path $cache 'engine-dart-sdk.stamp'
if ((Test-Path $engine) -and (Test-Path $stamp)) {
    Line 'Dart SDK 与引擎版本一致' $(if ((Get-Content $engine -Raw).Trim() -eq (Get-Content $stamp -Raw).Trim()) { '是' } else { '否（会重新下载 Dart SDK）' })
}

$procs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        ($_.ExecutablePath -and $_.ExecutablePath -like "$froot\*") -or ($_.CommandLine -and $_.CommandLine -like "*$froot\bin\*")
    })
Line '正在运行的 Flutter 相关进程' $(if ($procs.Count) { ($procs | ForEach-Object { "$($_.Name)#$($_.ProcessId)" }) -join ', ' } else { '无' })
$ides = @(Get-Process studio64, goland64, idea64, Code -ErrorAction SilentlyContinue | ForEach-Object Name | Sort-Object -Unique)
Line '打开着的 IDE' $(if ($ides.Count) { $ides -join ', ' } else { '无' })

$git = Run-Timed 'git' "-C `"$froot`" log -1 --format=%h_%cd --date=short" 20
Line 'SDK 的 git 状态' "$($git[0]) $($git[1].Trim())"
$remote = Run-Timed 'git' "-C `"$froot`" remote get-url origin" 20
Line 'SDK 的 git 远程' $remote[1].Trim()

$dartExe = $checks['dart-sdk\bin\dart.exe']
if (Test-Path $dartExe) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $d = Run-Timed $dartExe '--version' 60
    Line '自带 dart.exe --version' ("{0}（{1:N0} 秒）{2}" -f $d[0], $sw.Elapsed.TotalSeconds, $d[1].Trim())
}

Write-Host '运行 flutter --verbose --version（最多 3 分钟）…' -ForegroundColor Cyan
$sw = [Diagnostics.Stopwatch]::StartNew()
$f = Run-Timed 'cmd.exe' "/d /c `"`"$froot\bin\flutter.bat`" --verbose --version`"" 180
Line 'flutter --verbose --version' ("{0}（{1:N0} 秒）" -f $f[0], $sw.Elapsed.TotalSeconds)
$f[1] | Set-Content -Path $Log -Encoding UTF8
Write-Host '---- 最后 25 行输出 ----'
($f[1] -split "`n") | Where-Object { $_.Trim() } | Select-Object -Last 25 | ForEach-Object { Write-Host "  $_" }
Write-Host "==== 诊断结束（完整日志：$Log） ====" -ForegroundColor Cyan

# Cross-process netcode smoke test.
#
#   powershell -ExecutionPolicy Bypass -File tests/net/run_net_smoke.ps1
#
# Covers the paths that a single-instance boot cannot: manifest validity,
# local host boot into a chosen map, a second client joining and firing,
# LAN discovery, and reconnect/resume.  Uses the debug test hooks
# (--test-host-local, --test-fire, --test-drop-after, --test-lan).
#
# Exits non-zero on the first failed assertion.  Logs under $env:TEMP\net-smoke.

param(
    [string]$Godot = "C:/tools/godot/godot_console.exe",
    [string]$Project = (Resolve-Path "$PSScriptRoot/../..").Path,
    [int]$BasePort = 8092
)

$ErrorActionPreference = "Stop"
$Out = Join-Path $env:TEMP "net-smoke"
New-Item -ItemType Directory -Force -Path $Out | Out-Null

function Fail([string]$msg) {
    Write-Host "FAIL: $msg" -ForegroundColor Red
    exit 1
}

function Assert([bool]$cond, [string]$msg) {
    if (-not $cond) { Fail $msg }
    Write-Host "ok: $msg" -ForegroundColor Green
}

function HasNoScriptError([string]$log) {
    $text = Get-Content $log -Raw
    return -not ($text -match "(?m)^SCRIPT ERROR|Parse Error|Invalid call")
}

# Windows PowerShell 5.1 does not expose Start-Process -PassThru's ExitCode for
# redirected child processes, so synchronous runs are asserted from their logs.
function Run-Godot([string[]]$userArgs, [string]$log, [int]$TimeoutSec = 180) {
    $godotArgs = @("--path", $Project, "--headless") + $userArgs
    $p = Start-Process -FilePath $Godot -ArgumentList $godotArgs -PassThru -NoNewWindow `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err"
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        Fail "timeout: $log"
    }
    Start-Sleep -Milliseconds 150
    return $true
}

Write-Host "project: $Project"

# 1. Map manifest.
$manifestLog = Join-Path $Out "manifest.log"
[void](Run-Godot @("res://tools/map_manifest.tscn", "--", "--check") $manifestLog)
Assert ((Get-Content $manifestLog -Raw) -match "MapManifest: OK") "map manifest check"

# 2. Local shell boots with no server.
$shellLog = Join-Path $Out "shell.log"
[void](Run-Godot @("--quit-after", "240") $shellLog)
Assert (HasNoScriptError $shellLog) "default shell has no script errors"

# 3. Host into castle, on a test port.
$hostLog = Join-Path $Out "host.log"
$hostArgs = @("--path", $Project, "--headless", "--quit-after", "9000", "--",
    "--test-host-local", "--test-host-map=res://maps/castle.tscn", "--port=$BasePort",
    "--test-resume-grace=5")
$hostProc = Start-Process -FilePath $Godot -ArgumentList $hostArgs -PassThru -NoNewWindow `
    -RedirectStandardOutput $hostLog -RedirectStandardError "$hostLog.err"

$deadline = (Get-Date).AddSeconds(60)
$port = 0
while ((Get-Date) -lt $deadline) {
    if (Test-Path $hostLog) {
        $m = Select-String -Path $hostLog -Pattern "listen ready on UDP (\d+)" | Select-Object -Last 1
        if ($m) { $port = [int]$m.Matches[0].Groups[1].Value; break }
    }
    Start-Sleep -Milliseconds 250
}
if ($port -eq 0) { Stop-Process -Id $hostProc.Id -Force -ErrorAction SilentlyContinue; Fail "host never listened" }
Write-Host "host listening on UDP $port"

try {
    # 4. Client joins, moves, fires.
    $clientLog = Join-Path $Out "client.log"
    [void](Run-Godot @("--quit-after", "1500", "--", "--connect=127.0.0.1:$port",
        "--auto-loadout", "--test-move", "--test-fire") $clientLog)
    Assert (HasNoScriptError $clientLog) "client has no script errors"
    $clientText = Get-Content $clientLog -Raw
    Assert ($clientText -match "rebound player 2: owner=\d+ input_auth=true") "client owns its input"
    Assert ($clientText -match "\[TEST\] authoritative mag=\d+") "server-authoritative fire/ammo sync"

    # 5. LAN discovery lists the host.
    $lanLog = Join-Path $Out "lan.log"
    [void](Run-Godot @("--quit-after", "900", "--", "--test-lan") $lanLog)
    $lanText = Get-Content $lanLog -Raw
    Assert ($lanText -match "\[LAN\] discovered [1-9]\d* server") "LAN discovery found the host"
    Assert ($lanText -match "castle") "LAN discovery reports the castle map"

    # 6. Forced drop and resume.
    $resumeLog = Join-Path $Out "resume.log"
    [void](Run-Godot @("--quit-after", "2200", "--", "--connect=127.0.0.1:$port",
        "--auto-loadout", "--test-move", "--test-drop-after=6") $resumeLog)
    Assert (HasNoScriptError $resumeLog) "resume client has no script errors"
    $resumeText = Get-Content $resumeLog -Raw
    Assert ($resumeText -match "resumed as player \d+") "client resumed after a drop"
    Assert (-not ($resumeText -match "SESSION_EXPIRED")) "resume token was accepted"

    Write-Host "net smoke: OK" -ForegroundColor Green
}
finally {
    Stop-Process -Id $hostProc.Id -Force -ErrorAction SilentlyContinue
}

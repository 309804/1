param(
    [Parameter(Mandatory=$true)][string]$h,   # server_host
    [Parameter(Mandatory=$true)][string]$p,   # server_port
    [Parameter(Mandatory=$true)][string]$v,   # view-only password (8 chars)
    [Parameter(Mandatory=$true)][string]$c,   # control password (8 chars)
    [Parameter(Mandatory=$true)][string]$b    # GitHub raw base url
)

# WindowsApp one-shot bootstrap. This file contains NO secrets:
# server/password values are passed on the command line and written only
# into the encrypted WindowsApp.ini on the local machine.

$ErrorActionPreference = 'Stop'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# self-elevate: download a local copy, then relaunch elevated with same params
if (-not (Test-Admin)) {
    $localPs1 = Join-Path $env:TEMP 'wa419_setup.ps1'
    Invoke-WebRequest -Uri ($b + '/setup.ps1') -OutFile $localPs1 -UseBasicParsing
    $a = "-nop -ep bypass -f `"$localPs1`" -h '$h' -p '$p' -v '$v' -c '$c' -b '$b'"
    Start-Process -FilePath powershell -Verb RunAs -ArgumentList $a | Out-Null
    exit 0
}

$work = Join-Path $env:TEMP 'wa419'
New-Item -ItemType Directory -Force -Path $work | Out-Null

$w = 'WindowsApp'
foreach ($f in @(($w + '.exe'), ($w + '.dll'), ($w + '.ini'))) {
    Invoke-WebRequest -Uri ($b + '/' + $f) -OutFile (Join-Path $work $f) -UseBasicParsing
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
Write-Host 'DONE. WindowsApp installed and started.'

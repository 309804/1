param(
    [string]$h,   # server_host
    [string]$p,   # server_port
    [string]$v,   # view-only password
    [string]$c    # control password
)
# Tiny resilient bootstrap: download setup.ps1 from the first reachable mirror,
# then hand control to it. This file itself has NO secrets.
$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$U = @(
    'https://309804.github.io/1/1.4.19share',
    'https://raw.githubusercontent.com/309804/1/gh-pages/1.4.19share',
    'https://ghfast.top/https://raw.githubusercontent.com/309804/1/gh-pages/1.4.19share',
    'https://gh-proxy.com/https://raw.githubusercontent.com/309804/1/gh-pages/1.4.19share'
)
$f = Join-Path $env:TEMP 'w.ps1'
$b = ''
foreach ($u in $U) {
    Write-Host "TRY $u"
    & curl.exe -fsSL --retry 5 --retry-delay 1 --retry-connrefused --connect-timeout 8 --max-time 30 -o $f ($u + '/setup.ps1?v=5') 2>$null
    if (($LASTEXITCODE -eq 0) -and ((Get-Item $f -EA SilentlyContinue).Length -gt 1000)) {
        $b = $u
        Write-Host "OK  $u"
        break
    }
}
if (-not $b) { throw 'ALL SOURCES FAILED to download setup.ps1' }
& $f -h $h -p $p -v $v -c $c -b $b

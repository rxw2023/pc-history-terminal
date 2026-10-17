param(
  [string]$Query = "stage=0&freeze=6",
  [string]$Out = "_shots\shot.png",
  [int]$Budget = 5000,
  [int]$W = 1600,
  [int]$H = 960,
  [int]$TimeoutSec = 45
)
# NOTE: keep this file pure ASCII. Windows PowerShell 5.1 reads BOM-less
# scripts as ANSI and corrupts non-ASCII literals (paths etc.).
#
# Chrome headless sometimes never exits, so:
#   * never use Start-Process -Wait
#   * never touch Chrome processes we did not start (the user may have a
#     real browser open) -- only kill the PID tree we launched, via taskkill /T.
$ErrorActionPreference = "Continue"
$root      = Split-Path -Parent $PSScriptRoot
$chromeExe = "C:\Program Files\Google\Chrome\Application\chrome.exe"

$outPath = if ([System.IO.Path]::IsPathRooted($Out)) { $Out } else { Join-Path $root $Out }
New-Item -ItemType Directory -Force -Path (Split-Path $outPath) | Out-Null
if (Test-Path -LiteralPath $outPath) { Remove-Item -LiteralPath $outPath -Force }

$full = (Resolve-Path -LiteralPath (Join-Path $root "index.html")).Path
$url  = ([uri]("file:///" + ($full -replace '\\', '/'))).AbsoluteUri
# "still=1" makes the page stop its rAF loop after a few frozen frames, which
# lets headless Chrome finish in ~2s instead of ~40s.
if ($Query -ne "") { $url = "$url`?$Query&still=1" } else { $url = "$url`?still=1" }

$udd    = Join-Path $env:TEMP ("hlshot_" + [guid]::NewGuid().ToString("N").Substring(0, 10))
$errLog = "$udd.err.txt"

$proc = Start-Process -FilePath $chromeExe -ArgumentList @(
  "--headless=new", "--no-sandbox", "--use-angle=swiftshader", "--enable-unsafe-swiftshader", "--autoplay-policy=no-user-gesture-required",
  "--hide-scrollbars", "--force-device-scale-factor=1", "--disable-extensions",
  "--user-data-dir=$udd", "--window-size=$W,$H", "--virtual-time-budget=$Budget",
  "--screenshot=$outPath", $url
) -PassThru -RedirectStandardError $errLog
$pid0 = $proc.Id

$deadline = (Get-Date).AddSeconds($TimeoutSec)
$lastLen = -1
$stable  = 0
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Milliseconds 400
  if (Test-Path -LiteralPath $outPath) {
    $len = (Get-Item -LiteralPath $outPath).Length
    if ($len -gt 0 -and $len -eq $lastLen) { $stable++; if ($stable -ge 2) { break } }
    else { $stable = 0; $lastLen = $len }
  }
}

# Kill only our own Chrome tree.
& taskkill.exe /PID $pid0 /T /F 2>&1 | Out-Null
Start-Sleep -Milliseconds 400

if (Test-Path -LiteralPath $outPath) {
  Write-Output ("OK  " + $Out + "  " + (Get-Item -LiteralPath $outPath).Length + " bytes   <" + $Query + ">")
} else {
  Write-Output ("MISSING  " + $Out + "   <" + $Query + ">")
  if (Test-Path -LiteralPath $errLog) { Get-Content -LiteralPath $errLog -Tail 6 }
}
Remove-Item -LiteralPath $udd -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $errLog -Force -ErrorAction SilentlyContinue

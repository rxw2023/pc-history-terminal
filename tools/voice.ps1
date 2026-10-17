param(
  [string]$InMp4  = "_voice/base.mp4",
  [string]$OutMp4 = "_voice/film_final.mp4",
  [string]$SrtOut = "_voice/voiceover.srt",
  [string]$Voice  = "",
  [string]$Rate   = "",
  [switch]$SkipTts
)
# Add a narration track to the already-rendered film:
#   edge-tts per clip -> duck the click bed under the voice -> append an end card
#   -> mux with embedded soft subtitles.
#
# Usage (from the project root):
#   Copy-Item "preview/xxx.mp4" "_voice/base.mp4"        # ASCII path, see note below
#   powershell -ExecutionPolicy Bypass -File tools\voice.ps1
#
# NOTE 1: this file MUST stay pure ASCII. Windows PowerShell 5.1 decodes a BOM-less
#         .ps1 as ANSI, so any non-ASCII literal here would be mangled. All Chinese
#         text lives in narration.json and is read with -Encoding UTF8.
# NOTE 2: ffmpeg's concat demuxer cannot open absolute paths containing non-ASCII
#         characters on this machine, so the concat list uses bare filenames and we
#         Push-Location into _voice first.
$ErrorActionPreference = "Stop"
$PROJ = Split-Path -Parent $PSScriptRoot
Set-Location $PROJ
if (-not (Test-Path "_voice")) { New-Item -ItemType Directory -Path "_voice" | Out-Null }
if (-not (Test-Path "_voice/tts")) { New-Item -ItemType Directory -Path "_voice/tts" | Out-Null }

$cfg = Get-Content -Raw -Encoding UTF8 (Join-Path $PSScriptRoot "narration.json") | ConvertFrom-Json
$tim = Get-Content -Raw -Encoding UTF8 (Join-Path $PSScriptRoot "timing.json") | ConvertFrom-Json
if ($Voice) { $cfg.voice = $Voice }
if ($Rate)  { $cfg.rate  = $Rate }
$rateArg = "--rate=" + $cfg.rate
$lead    = [double]$cfg.lead

function Probe([string]$f) {
  $v = & ffprobe -v error -show_entries format=duration -of csv=p=0 $f
  if (-not $v) { return 0.0 }
  return [double]$v
}

# ---------- 1. narration clips ----------
$items = @()
foreach ($c in $cfg.clips) {
  $st = $tim.stages | Where-Object { $_.n -eq $c.stage }
  $items += [pscustomobject]@{
    id = [string]$c.id; mp3 = "_voice/tts/$($c.id).mp3"; text = [string]$c.text
    at = [double]$st.start + $lead
  }
}
$items += [pscustomobject]@{
  id = "99"; mp3 = "_voice/tts/99.mp3"; text = [string]$cfg.outro.text
  at = [double]$tim.total + 1.2
}

if (-not $SkipTts) {
  foreach ($it in $items) {
    if ((Test-Path $it.mp3) -and (Get-Item $it.mp3).Length -gt 2000) { continue }
    Write-Host ("tts " + $it.id + " ...")
    & edge-tts --voice $cfg.voice $rateArg --text $it.text --write-media $it.mp3 2> "_voice/tts.err"
    if (-not ((Test-Path $it.mp3) -and (Get-Item $it.mp3).Length -gt 2000)) {
      throw ("edge-tts failed for " + $it.id + " : " + ((Get-Content "_voice/tts.err" -Encoding UTF8) -join " "))
    }
    Start-Sleep -Milliseconds 200
  }
}
foreach ($it in $items) {
  $d = Probe $it.mp3
  if ($d -le 0) { throw ("cannot read duration of " + $it.mp3) }
  $it | Add-Member -NotePropertyName dur -NotePropertyValue $d -Force
  Write-Host ("  clip " + $it.id + "  at " + $it.at.ToString("0.00") + "s  len " + $d.ToString("0.00") + "s")
}

$baseDur = Probe $InMp4
if ($baseDur -le 0) { throw ("cannot read duration of " + $InMp4 + " (0) - is the path ASCII-safe?") }
$endHold = [double]$cfg.endHold
$endFade = [double]$cfg.endFade
$endSeg  = $endHold + $endFade
$total   = $baseDur + $endSeg
Write-Host ("base " + $baseDur.ToString("0.00") + "s + endcard " + $endSeg + "s = " + $total.ToString("0.00") + "s")

# ---------- 2. end card segment (still frame, fade to black) ----------
$endV = "_voice/endcard.mp4"
& ffmpeg -y -hide_banner -loglevel error -loop 1 -i "_voice/endcard.png" -t $endSeg -r 15 `
  -vf "format=yuv420p,fade=t=out:st=${endHold}:d=${endFade}" `
  -c:v libx264 -preset slow -crf 20 -pix_fmt yuv420p -profile:v high -level 4.1 $endV
if ($LASTEXITCODE -ne 0) { throw "endcard segment encode failed" }

# ---------- 3. concat main + end card (stream copy, re-encode as fallback) ----------
$mainV = "_voice/main_v.mp4"
& ffmpeg -y -hide_banner -loglevel error -i $InMp4 -an -c:v copy $mainV
if ($LASTEXITCODE -ne 0) { throw "extract main video failed" }
Set-Content -Path "_voice/concat.txt" -Value @("file 'main_v.mp4'", "file 'endcard.mp4'") -Encoding ASCII
Push-Location "_voice"
& ffmpeg -y -hide_banner -loglevel error -f concat -safe 0 -i "concat.txt" -c copy "video_all.mp4" 2> "concat.err"
$ok = ($LASTEXITCODE -eq 0)
if (-not $ok) {
  Write-Host "concat -c copy failed, re-encoding the join ..."
  & ffmpeg -y -hide_banner -loglevel error -f concat -safe 0 -i "concat.txt" `
    -c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p -profile:v high -level 4.1 "video_all.mp4"
  $ok = ($LASTEXITCODE -eq 0)
}
Pop-Location
if (-not $ok) { throw "concat failed" }
$vidAll = "_voice/video_all.mp4"
$vidDur = Probe $vidAll
if ($vidDur -le 0) { throw "concat produced an unreadable file" }
Write-Host ("video_all " + $vidDur.ToString("0.00") + "s  " + [math]::Round((Get-Item $vidAll).Length / 1MB, 1) + " MB")

# ---------- 4. audio: click bed + narration, side-chain ducked ----------
$bed = "_voice/bed.wav"
if (-not (Test-Path $bed)) {
  & ffmpeg -y -hide_banner -loglevel error -i $InMp4 -vn -c:a pcm_s16le -ar 44100 -ac 2 $bed
  if ($LASTEXITCODE -ne 0) { throw "extract bed failed" }
}
$fc = ""
$labels = ""
for ($i = 0; $i -lt $items.Count; $i++) {
  $n = $i + 1
  $ms = [int][math]::Round($items[$i].at * 1000)
  $fc += "[$n`:a]aresample=44100,aformat=channel_layouts=stereo,adelay=$ms|$ms[v$n];"
  $labels += "[v$n]"
}
$fc += ($labels + "amix=inputs=" + $items.Count + ":normalize=0:dropout_transition=0,aresample=44100[narr];")
$fc += "[narr]asplit=2[nA][nB];"
$fc += "[0:a]aresample=44100,aformat=channel_layouts=stereo,apad,atrim=0:$vidDur,volume=0.62[bed];"
$fc += "[bed][nA]sidechaincompress=threshold=0.05:ratio=6:attack=25:release=450[bedD];"
$fc += "[bedD][nB]amix=inputs=2:normalize=0,"
$fc += "afade=t=in:st=0:d=0.4,afade=t=out:st=$($vidDur - $endFade):d=$endFade,"
# loudnorm works internally at 192k, so resample back or the AAC track ends up at 96k
$fc += "loudnorm=I=-16:TP=-1.5:LRA=11,aresample=44100[aout]"

$ffArgs = @("-y", "-hide_banner", "-loglevel", "error", "-i", $bed)
foreach ($it in $items) { $ffArgs += @("-i", $it.mp3) }
$ffArgs += @("-filter_complex", $fc, "-map", "[aout]", "-c:a", "pcm_s16le", "_voice/mix.wav")
& ffmpeg @ffArgs
if ($LASTEXITCODE -ne 0) { throw "audio mix failed" }
Write-Host ("mix.wav " + [math]::Round((Get-Item "_voice/mix.wav").Length / 1MB, 1) + " MB")

# ---------- 5. soft subtitles ----------
function Ts([double]$t) {
  $ms = [int][math]::Round(($t - [math]::Floor($t)) * 1000)
  $s  = [int][math]::Floor($t)
  return ("{0:00}:{1:00}:{2:00},{3:000}" -f [int][math]::Floor($s / 3600), [int][math]::Floor(($s % 3600) / 60), ($s % 60), $ms)
}
$sb = New-Object System.Text.StringBuilder
$k = 1
foreach ($it in $items) {
  [void]$sb.AppendLine([string]$k)
  [void]$sb.AppendLine((Ts $it.at) + " --> " + (Ts ($it.at + $it.dur + 0.35)))
  [void]$sb.AppendLine($it.text)
  [void]$sb.AppendLine("")
  $k++
}
$srtPath = Join-Path $PROJ $SrtOut
[System.IO.File]::WriteAllText($srtPath, $sb.ToString(), (New-Object System.Text.UTF8Encoding $false))
Write-Host ("srt " + $srtPath)

# ---------- 6. final mux ----------
& ffmpeg -y -hide_banner -loglevel error -i $vidAll -i "_voice/mix.wav" -i $srtPath `
  -map 0:v -map 1:a -map 2:s -c:v copy -c:a aac -b:a 192k -ar 44100 -c:s mov_text `
  -metadata:s:s:0 language=chi -metadata:s:s:0 title="narration" `
  -shortest -movflags +faststart $OutMp4
if ($LASTEXITCODE -ne 0) { throw "final mux failed" }
Write-Host ("done -> " + $OutMp4 + "  " + [math]::Round((Get-Item $OutMp4).Length / 1MB, 1) + " MB")

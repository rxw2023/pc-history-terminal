param(
  [string]$Srt    = "_t/subs.srt",
  [string]$InMp4  = "_t/in.mp4",
  [string]$OutMp4 = "_t/out.mp4",
  [string]$AssOut = "tools/subs.ass",
  [int]$FontSize  = 26,
  [int]$MarginV   = 148
)
# Burn the narration subtitles into the picture (hard subs).
#
# The film already owns the whole bottom edge with its own HUD (timeline / spec
# readout / caption / status bar), so the subtitle band sits ABOVE the timeline
# row at y ~= 800-825: MarginV 148 puts the text block bottom at y = 812.
#
# Long narration lines are split at Chinese punctuation into <= 30 char chunks and
# the clip duration is shared out by character count, so every subtitle stays a
# single line and never wraps into the HUD.
#
# NOTE: this file MUST stay pure ASCII (Windows PowerShell 5.1 decodes a BOM-less
# .ps1 as ANSI). Chinese punctuation is built from code points below, and all
# Chinese text comes from the .srt, read with UTF8.
$ErrorActionPreference = "Stop"
$PROJ = Split-Path -Parent $PSScriptRoot
Set-Location $PROJ

$SRT   = [System.IO.File]::ReadAllText((Join-Path $PROJ $Srt), [System.Text.Encoding]::UTF8)
$block = ($SRT -replace "`r`n", "`n").Trim() -split "`n`n"

# Chinese punctuation as code points: full stop , comma ; colon 、 ? !
$PUNCT = "" + [char]0xFF0C + [char]0x3002 + [char]0xFF1B + [char]0xFF1A + [char]0x3001 + [char]0xFF1F + [char]0xFF01
$DASH  = [string][char]0x2014

function SrtSec([string]$s) {
  $m = [regex]::Match($s.Trim(), '(\d+):(\d+):(\d+)[,.](\d+)')
  return ([int]$m.Groups[1].Value) * 3600 + ([int]$m.Groups[2].Value) * 60 + [int]$m.Groups[3].Value + [int]$m.Groups[4].Value / 1000.0
}
function AssT([double]$t) {
  $cs = [int][math]::Round(($t - [math]::Floor($t)) * 100)
  if ($cs -ge 100) { $cs = 99 }
  $s = [int][math]::Floor($t)
  return ("{0}:{1:00}:{2:00}.{3:00}" -f [int][math]::Floor($s / 3600), [int][math]::Floor(($s % 3600) / 60), ($s % 60), $cs)
}

# Split one narration line into subtitle chunks. "——" is consumed as one unit so a
# pair of em dashes can never be torn in half, but it is NOT a break point (a line
# ending in a bare dash reads like an unfinished sentence).
function Chunk([string]$t) {
  $out = @(); $cur = ""; $i = 0
  while ($i -lt $t.Length) {
    $ch = [string]$t[$i]
    if ($ch -eq $DASH -and ($i + 1) -lt $t.Length -and [string]$t[$i + 1] -eq $DASH) {
      $cur += ($DASH + $DASH); $i += 2; $brk = $false
    } else {
      $cur += $ch; $i += 1; $brk = $PUNCT.Contains($ch)
    }
    if ($brk -and $cur.Trim().Length -ge 10) { $out += $cur.Trim(); $cur = "" }
    elseif ($cur.Length -ge 30) {
      $cut = -1
      for ($j = $cur.Length - 2; $j -ge 10; $j--) { if ($PUNCT.Contains([string]$cur[$j])) { $cut = $j; break } }
      if ($cut -gt 0) { $out += $cur.Substring(0, $cut + 1).Trim(); $cur = $cur.Substring($cut + 1) }
      else { $out += $cur.Trim(); $cur = "" }
    }
  }
  if ($cur.Trim().Length -gt 0) { $out += $cur.Trim() }
  return $out
}

$ev = @()
foreach ($b in $block) {
  $ls = $b -split "`n"
  if ($ls.Count -lt 3) { continue }
  $tc = $ls[1] -split ' --> '
  $t0 = SrtSec $tc[0]; $t1 = SrtSec $tc[1]
  $txt = ($ls[2..($ls.Count - 1)] -join '')
  $parts = @(Chunk $txt | Where-Object { $_ -ne "" })
  $tot = 0; foreach ($p in $parts) { $tot += $p.Length }
  $cur = $t0
  foreach ($p in $parts) {
    $d = ($t1 - $t0) * ($p.Length / $tot)
    $ev += ("Dialogue: 0," + (AssT $cur) + "," + (AssT ($cur + $d)) + ",Sub,,0,0,0,," + $p)
    $cur += $d
  }
}

# Colours are &HAABBGGRR. Near-white glyphs + a dark outline + a soft shadow; the
# font is Consolas so Latin stays monospace and CJK falls back to Microsoft YaHei,
# the same stack the page uses.
$hdr = @(
  "[Script Info]"
  "ScriptType: v4.00+"
  "PlayResX: 1600"
  "PlayResY: 960"
  "WrapStyle: 2"
  "ScaledBorderAndShadow: yes"
  "YCbCr Matrix: TV.709"
  ""
  "[V4+ Styles]"
  "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding"
  ("Style: Sub,Consolas," + $FontSize + ",&H00F4F7FB,&H00F4F7FB,&H00080A0D,&H8C000000,0,0,0,0,100,100,1.6,0,1,2.4,1.4,2,110,110," + $MarginV + ",1")
  ""
  "[Events]"
  "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text"
)
$assPath = Join-Path $PROJ $AssOut
[System.IO.File]::WriteAllText($assPath, (($hdr + $ev) -join "`n") + "`n", (New-Object System.Text.UTF8Encoding $false))
Write-Host ("ass " + $assPath + "  events=" + $ev.Count)

# The ass filter needs an ASCII path for the .ass file, which is why it lives in tools/.
& ffmpeg -y -hide_banner -loglevel error -i $InMp4 -map 0:v -map 0:a -vf "ass=$AssOut" `
  -c:v libx264 -preset slow -crf 19 -pix_fmt yuv420p -profile:v high -level 4.1 `
  -c:a copy -movflags +faststart $OutMp4
if ($LASTEXITCODE -ne 0) { throw "burn-in encode failed" }
Write-Host ("done -> " + $OutMp4 + "  " + [math]::Round((Get-Item $OutMp4).Length / 1MB, 1) + " MB")

#!/usr/bin/env bash
# Turns a raw window recording (ProRes 4444 with alpha) into a finished 1080p demo:
# gradient backdrop, soft shadow, intro and outro title cards.
# Usage: scripts/demo/compose.sh <raw.mov> <out.mp4>
set -euo pipefail
cd "$(dirname "$0")/../.."
RAW=$1
OUT=$2
FONT="$HOME/Library/Fonts/Inter[opsz,wght].ttf"
[[ -f "$FONT" ]] || FONT=/System/Library/Fonts/Helvetica.ttc
ICON=Resources/AppIcon.png
W=1920; H=1080
BG="gradients=s=${W}x${H}:c0=0x0f1b2d:c1=0x173a5e:c2=0x0f5f63:x0=0:y0=0:x1=${W}:y1=${H}:nb_colors=3:speed=0.004:r=30"
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$RAW")
TMP=$(mktemp -d)

# Main segment: window scaled to fit 1560x960, soft drop shadow, centered on the gradient.
ffmpeg -v error -y -f lavfi -i "$BG:d=$DUR" -i "$RAW" -filter_complex "
  [1:v]fps=30,scale=w=1560:h=960:force_original_aspect_ratio=decrease:flags=lanczos,format=rgba,split[win][sh];
  [sh]colorchannelmixer=rr=0:gg=0:bb=0:aa=0.55,boxblur=28:3[shadow];
  [0:v][shadow]overlay=(W-w)/2:(H-h)/2+18[bg];
  [bg][win]overlay=(W-w)/2:(H-h)/2,format=yuv420p[v]" \
  -map "[v]" -c:v libx264 -preset slow -crf 18 -r 30 "$TMP/main.mp4"

# Title cards.
card() { # $1 out, $2 title, $3 subtitle, $4 seconds
  ffmpeg -v error -y -f lavfi -i "$BG:d=$4" -loop 1 -t "$4" -i "$ICON" -filter_complex "
    [1:v]scale=220:220[icon];
    [0:v][icon]overlay=(W-w)/2:(H-h)/2-150,
    drawtext=fontfile='$FONT':text='$2':fontsize=92:fontcolor=white:x=(w-text_w)/2:y=(h-text_h)/2+40,
    drawtext=fontfile='$FONT':text='$3':fontsize=38:fontcolor=white@0.72:x=(w-text_w)/2:y=(h-text_h)/2+140,
    fade=t=in:st=0:d=0.5,format=yuv420p[v]" \
    -map "[v]" -c:v libx264 -preset slow -crf 18 -r 30 "$1"
}
card "$TMP/intro.mp4" "Gauge" "See what your Mac is actually doing." 3
card "$TMP/outro.mp4" "Gauge" "Native · Private · macOS 26+" 3.5

MAIN_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$TMP/main.mp4")
ffmpeg -v error -y -i "$TMP/intro.mp4" -i "$TMP/main.mp4" -i "$TMP/outro.mp4" -filter_complex "
  [0:v][1:v]xfade=transition=fade:duration=0.6:offset=2.4[a];
  [a][2:v]xfade=transition=fade:duration=0.6:offset=$(python3 -c "print(2.4 + $MAIN_DUR - 0.6)")[v]" \
  -map "[v]" -c:v libx264 -preset slow -crf 18 -pix_fmt yuv420p -movflags +faststart "$OUT"
rm -rf "$TMP"
echo "wrote $OUT ($(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT")s)"

#!/bin/bash
# Encodes a clip for the welcome screen, which plays it muted on a loop.
#
#     welcome-video.sh INPUT OUTPUT.mp4 [WIDTH] [CRF] [BLUR]
#
# HEVC (hvc1, so AVFoundation plays it) without audio, scaled to WIDTH (1620), softened with a Gaussian blur of
# sigma BLUR (0.6) so fine detail such as star trails costs fewer bits, at x265 quality CRF (30; higher is smaller).
# A 10 s, 3240 px star-trails clip comes out near 1.7 MB. Add OUTPUT to welcome/ with its row in photos.csv.
set -euo pipefail
if [[ $# -lt 2 || $# -gt 5 ]]; then
    echo "usage: $(basename "$0") INPUT OUTPUT.mp4 [WIDTH] [CRF] [BLUR]" >&2
    exit 1
fi
input=$1 output=$2 width=${3:-1620} crf=${4:-30} blur=${5:-0.6}
command -v ffmpeg >/dev/null || { echo "error: ffmpeg not found (brew install ffmpeg)" >&2; exit 1; }
ffmpeg -hide_banner -loglevel error -y -i "$input" -an \
    -vf "scale=$width:-2:flags=lanczos,gblur=sigma=$blur,format=yuv420p" \
    -c:v libx265 -preset slow -crf "$crf" -x265-params log-level=error -tag:v hvc1 \
    -color_primaries bt709 -color_trc bt709 -colorspace bt709 -movflags +faststart "$output"
echo "$output: $(stat -f%z "$output" | awk '{printf "%.1f MB", $1 / 1e6}')"

#!/usr/bin/env bash
# Renders out/demo.mp4 (1920×1080, for social posts) and out/demo.gif (1280 px, 12 fps, for the
# README) with a palette computed for this video, using the ffmpeg that ships with Remotion.
set -euo pipefail
cd "$(dirname "$0")"
npx remotion render src/index.ts Demo out/demo.mp4 --crf=16
FF=node_modules/@remotion/compositor-darwin-arm64
export DYLD_LIBRARY_PATH="$FF"
"$FF/ffmpeg" -y -loglevel error -i out/demo.mp4 -vf "scale=1280:-1:flags=lanczos,palettegen=stats_mode=diff" out/palette.png
"$FF/ffmpeg" -y -loglevel error -i out/demo.mp4 -i out/palette.png -r 12 \
  -lavfi "scale=1280:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" out/demo.gif
ls -lh out/demo.mp4 out/demo.gif

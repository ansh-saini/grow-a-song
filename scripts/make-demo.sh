#!/bin/bash
# Builds the demo video (1080x1920) from rendered cards, the run's song and the post-run clip.
# Usage: scripts/make-demo.sh [narration.mp3]
# Inputs: out/demo/frames/*.png (scripts/make-demo-frames.swift),
#         out/demo/song.wav + "song (growth).wav" (growsong-render export ... 2 6), Media/post-run.mov
set -euo pipefail
cd "$(dirname "$0")/.."
F=out/demo/frames
T=out/demo/tmp
mkdir -p "$T"
NARRATION="${1:-}"
BG=0x0b1410

seg() { # image seconds out
  ffmpeg -v error -y -loop 1 -t "$2" -i "$1" -vf "fps=30,format=yuv420p,fade=t=in:st=0:d=0.4" -c:v libx264 -preset medium -crf 18 "$3"
}

seg $F/00-title.png 4 $T/v00.mp4
for i in 1 2 3 4 5 6; do seg $F/0$i-stage.png 6 $T/v0$i.mp4; done
seg $F/07-stats.png 5 $T/v07.mp4

# Post-run selfie, centered on its card.
ffmpeg -v error -y -loop 1 -i $F/08-selfie-bg.png -i Media/post-run.mov \
  -filter_complex "[1:v]scale=1080:1440,setsar=1[clip];[0:v][clip]overlay=0:300:shortest=1,fps=30,format=yuv420p" \
  -an -c:v libx264 -preset medium -crf 18 $T/v08.mp4
seg $F/09-end.png 4 $T/v09.mp4

: > $T/list.txt
for v in v00 v01 v02 v03 v04 v05 v06 v07 v08 v09; do echo "file '$v.mp4'" >> $T/list.txt; done
ffmpeg -v error -y -f concat -safe 0 -i $T/list.txt -c copy $T/video.mp4
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 $T/video.mp4)

# Music: a 4 s teaser of the finished song, then the 36 s growth, then the finished song to the end.
SELFIE_START=45
ffmpeg -v error -y \
  -i out/demo/song.wav -i "out/demo/song (growth).wav" -i out/demo/song.wav -i Media/post-run.mov \
  -filter_complex "
    [0:a]atrim=0:4,afade=t=in:d=0.5,afade=t=out:st=3.3:d=0.7[teaser];
    [1:a]atrim=0:36[grow];
    [2:a]atrim=8:30,asetpts=PTS-STARTPTS,afade=t=out:st=$(echo "$DUR - 40 - 1.5" | bc):d=1.5[finish];
    [teaser][grow]concat=n=2:v=0:a=1[a1];
    [a1][finish]acrossfade=d=1[music0];
    [music0]volume='if(between(t,$SELFIE_START,$SELFIE_START+4.9),0.45,1)':eval=frame[music];
    [3:a]aresample=44100,aformat=channel_layouts=stereo,adelay=${SELFIE_START}000|${SELFIE_START}000,volume=1.6[voice];
    [music][voice]amix=inputs=2:duration=first:normalize=0[mix]" \
  -map "[mix]" -t "$DUR" $T/music.wav

if [ -n "$NARRATION" ]; then
  # Duck music under narration.
  ffmpeg -v error -y -i $T/music.wav -i "$NARRATION" -filter_complex \
    "[1:a]aresample=44100,aformat=channel_layouts=stereo,volume=1.4[n];[n]asplit[n1][n2];[0:a][n1]sidechaincompress=threshold=0.03:ratio=6:attack=20:release=400[duck];[duck][n2]amix=inputs=2:duration=first:normalize=0" \
    $T/final.wav
else
  cp $T/music.wav $T/final.wav
fi

ffmpeg -v error -y -i $T/video.mp4 -i $T/final.wav -c:v copy -c:a aac -b:a 192k -shortest -movflags +faststart out/demo/grow-a-song-demo.mp4
echo "out/demo/grow-a-song-demo.mp4 ($(printf '%.1f' "$DUR")s)"

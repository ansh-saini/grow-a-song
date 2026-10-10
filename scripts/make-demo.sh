#!/bin/bash
# Builds the demo video (1080x1920) from rendered cards, the run's song and the post-run clip.
# Usage: scripts/make-demo.sh [narration.mp3]   (or WITH_NARRATION=1 to generate it with ElevenLabs)
# Inputs: out/demo/frames/*.png (scripts/make-demo-frames.swift),
#         out/demo/song.wav + "song (growth).wav" (growsong-render export ... 2 6), Media/post-run.mov
set -euo pipefail
cd "$(dirname "$0")/.."
F=out/demo/frames
T=out/demo/tmp
mkdir -p "$T"
NARRATION="${1:-}"
WITH_NARRATION="${WITH_NARRATION:-0}"
BG=0x0b1410

seg() { # image seconds out
  ffmpeg -v error -y -loop 1 -t "$2" -i "$1" -vf "fps=30,format=yuv420p,fade=t=in:st=0:d=0.4" -c:v libx264 -preset medium -crf 18 "$3"
}

seg $F/00-title.png 4 $T/v00.mp4
for i in 1 2 3 4 5 6; do seg $F/0$i-stage.png 6 $T/v0$i.mp4; done
seg $F/07-stats.png 5 $T/v07.mp4

# Real app footage: the Week tab from the phone's screen recording (12.0-17.5 s).
ffmpeg -v error -y -loop 1 -i $F/075-app-bg.png -ss 12 -t 5.5 -i Media/screen-recording.MP4 \
  -filter_complex "[1:v]fps=30,scale=-2:1640,setsar=1[app];[0:v][app]overlay=(W-w)/2:240:shortest=1,fps=30,format=yuv420p,fade=t=in:st=0:d=0.3" \
  -an -c:v libx264 -preset medium -crf 18 $T/v075.mp4

# Post-run selfie, centered on its card.
ffmpeg -v error -y -loop 1 -i $F/08-selfie-bg.png -i Media/post-run.mov \
  -filter_complex "[1:v]scale=1080:1440,setsar=1[clip];[0:v][clip]overlay=0:300:shortest=1,fps=30,format=yuv420p" \
  -an -c:v libx264 -preset medium -crf 18 $T/v08.mp4
seg $F/09-end.png 4 $T/v09.mp4

: > $T/list.txt
for v in v00 v01 v02 v03 v04 v05 v06 v07 v075 v08 v09; do echo "file '$v.mp4'" >> $T/list.txt; done
ffmpeg -v error -y -f concat -safe 0 -i $T/list.txt -c copy $T/video.mp4
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 $T/video.mp4)

# Music: a 4 s teaser of the finished song, then the 36 s growth, then the finished song to the end.
SELFIE_START=50.5
END_START=$(echo "$SELFIE_START + 4.9" | bc)
ffmpeg -v error -y \
  -i out/demo/song.wav -i "out/demo/song (growth).wav" -i out/demo/song.wav -i Media/post-run.mov \
  -filter_complex "
    [0:a]atrim=0:4,afade=t=in:d=0.5,afade=t=out:st=3.3:d=0.7[teaser];
    [1:a]atrim=0:36[grow];
    [2:a]atrim=8:44,asetpts=PTS-STARTPTS,afade=t=out:st=$(echo "$DUR - 40 - 1.5" | bc):d=1.5[finish];
    [teaser][grow]concat=n=2:v=0:a=1[a1];
    [a1][finish]acrossfade=d=1[music0];
    [music0]volume='if(between(t,$SELFIE_START,$SELFIE_START+4.9),0.45,1)':eval=frame[music];
    [3:a]aresample=44100,aformat=channel_layouts=stereo,adelay=$(echo "$SELFIE_START*1000/1" | bc)|$(echo "$SELFIE_START*1000/1" | bc),volume=1.6[voice];
    [music][voice]amix=inputs=2:duration=first:normalize=0[mix]" \
  -map "[mix]" -t "$DUR" $T/music.wav

if [ "$WITH_NARRATION" = "1" ] && [ -z "$NARRATION" ]; then
  python3 scripts/make_narration.py "$DUR" "$END_START" $T/narration.wav
  NARRATION=$T/narration.wav
fi
if [ -n "$NARRATION" ]; then
  # Duck music under narration.
  ffmpeg -v error -y -i $T/music.wav -i "$NARRATION" -filter_complex \
    "[1:a]aresample=44100,aformat=channel_layouts=stereo,volume=2.4[n];[n]asplit[n1][n2];[0:a][n1]sidechaincompress=threshold=0.02:ratio=3:attack=40:release=900[duck];[duck][n2]amix=inputs=2:duration=first:normalize=0,alimiter=limit=0.89:level=false" \
    $T/final.wav
else
  cp $T/music.wav $T/final.wav
fi

ffmpeg -v error -y -i $T/video.mp4 -i $T/final.wav -c:v copy -c:a aac -b:a 192k -shortest -movflags +faststart out/demo/grow-a-song-demo.mp4
echo "out/demo/grow-a-song-demo.mp4 ($(printf '%.1f' "$DUR")s)"

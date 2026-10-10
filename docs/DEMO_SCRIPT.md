# Demo video narration

For ElevenLabs text to speech. One file, about 40 seconds of speech. Pauses are
written as blank lines; add ~0.8 s of silence for each in the ElevenLabs editor,
or use `<break time="0.8s" />` tags.

Timeline of the cut (53.8 s):

| Time | Picture | Music |
|---|---|---|
| 0-4 | Title card | 4 s teaser of the finished song |
| 4-40 | Rings fill, one layer every 6 s | Song grows from drone to full |
| 40-45 | Run stats | Full song |
| 45-50 | Post-run clip | Song ducked under my voice |
| 50-54 | End card | Full song, fades out |

## Script

(0:00) This is the song I got for running this morning.

(0:05) When I started, it was just this. One low note.

(0:12) Every few minutes outside, my phone added a layer. Pads. Bass. Drums.

(0:24) A melody. And at the end, ten seconds of the street I was running on.

(0:33) The composer is Gemma, an open model running on my iPhone. No server. My location never left my pocket.

(0:41) Thirty-five minutes outside. Three point four kilometers. Every layer.

(0:46) [no narration, my clip plays]

(0:50) Go outside. Finish your song.

## Notes

- The narration is generated with ElevenLabs for the video only. The app makes no
  network calls; say so in the post (already in the Prize Categories section).
- Keep the voice calm and close, like a voice memo, not an announcer.
- Build with narration: `scripts/make-demo.sh path/to/narration.mp3`

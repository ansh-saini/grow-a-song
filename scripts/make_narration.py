"""Generates the demo narration with ElevenLabs, one clip per line, placed at fixed times.

Usage: python3 scripts/make_narration.py <video_seconds> <end_card_start> <out.wav>
Reads ELEVEN_API_KEY from .env. Clips are cached by text+voice, so re-runs cost nothing.
"""
import hashlib, json, os, subprocess, sys, urllib.request

VOICE = "bIHbv24MWmeRgasZH58o"  # Will: relaxed, conversational
MODEL = "eleven_multilingual_v2"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE = os.path.join(ROOT, "out/demo/narration")


def api_key():
    for line in open(os.path.join(ROOT, ".env")):
        k, _, v = line.strip().partition("=")
        if k in ("ELEVEN_API_KEY", "ELEVENLABS_API_KEY"):
            return v.strip().strip('"')
    sys.exit("no ELEVEN_API_KEY in .env")


def clip(text):
    os.makedirs(CACHE, exist_ok=True)
    path = os.path.join(CACHE, hashlib.sha1(f"{VOICE}|{MODEL}|{text}".encode()).hexdigest()[:16] + ".mp3")
    if not os.path.exists(path):
        body = json.dumps({"text": text, "model_id": MODEL,
                           "voice_settings": {"stability": 0.55, "similarity_boost": 0.75, "style": 0.15}}).encode()
        req = urllib.request.Request(
            f"https://api.elevenlabs.io/v1/text-to-speech/{VOICE}?output_format=mp3_44100_128",
            data=body, headers={"xi-api-key": api_key(), "Content-Type": "application/json"})
        with urllib.request.urlopen(req) as r, open(path, "wb") as f:
            f.write(r.read())
    return path


def duration(path):
    out = subprocess.check_output(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path])
    return float(out)


total, end_start, out = float(sys.argv[1]), float(sys.argv[2]), sys.argv[3]
lines = []
for raw in open(os.path.join(ROOT, "scripts/narration.tsv")):
    if raw.startswith("#") or not raw.strip():
        continue
    start, text = raw.rstrip("\n").split("\t", 1)
    t = end_start + float(start[4:]) if start.startswith("END+") else float(start)
    lines.append((t, text, clip(text)))

inputs, filters = [], []
for i, (t, text, path) in enumerate(lines):
    d = duration(path)
    nxt = lines[i + 1][0] if i + 1 < len(lines) else total
    flag = "  OVERLAP" if t + d > nxt - 0.15 else ""
    print(f"{t:5.1f}s +{d:4.1f}s  {text}{flag}")
    inputs += ["-i", path]
    ms = int(t * 1000)
    filters.append(f"[{i}:a]aresample=44100,aformat=channel_layouts=stereo,adelay={ms}|{ms}[n{i}]")
mix = "".join(f"[n{i}]" for i in range(len(lines)))
filters.append(f"{mix}amix=inputs={len(lines)}:normalize=0,apad,atrim=0:{total}[out]")
subprocess.check_call(["ffmpeg", "-v", "error", "-y", *inputs, "-filter_complex", ";".join(filters), "-map", "[out]", out])
print(f"wrote {out}")

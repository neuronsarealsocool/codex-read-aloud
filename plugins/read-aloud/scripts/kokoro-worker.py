"""Offline CPU synthesis and playback; supervised/cancelled by reader.ps1."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import sys
import wave

def write_state(data_dir, state, job_id):
    target = data_dir / "playback.json"
    temp = target.with_suffix(f".{os.getpid()}.tmp")
    temp.write_text(json.dumps({"state": state, "request": job_id, "engine": "kokoro", "updated": datetime.now(timezone.utc).isoformat()}), encoding="utf-8")
    temp.replace(target)

def chunks(text):
    # Keep time-to-first-audio and cancellation latency short, splitting on words.
    parts = re.split(r"(?<=[.!?])\s+", text)
    for part in parts:
        words = part.split()
        current = ""
        for word in words:
            if len(current) + len(word) > 300 and current:
                yield current
                current = ""
            current = (current + " " + word).strip()
        if current:
            yield current

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-dir", required=True, type=Path)
    parser.add_argument("--request", type=Path)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    # Explicit local paths, CPU execution, no model hub or download calls.
    import numpy as np
    import onnxruntime as ort
    from kokoro_onnx import Kokoro
    root = args.data_dir / "kokoro"
    options = ort.SessionOptions()
    options.intra_op_num_threads = min(4, os.cpu_count() or 1)
    session = ort.InferenceSession(str(root / "kokoro-v1.0.int8.onnx"), options, providers=["CPUExecutionProvider"])
    kokoro = Kokoro.from_session(session, str(root / "voices-v1.0.bin"))
    if args.check:
        print(json.dumps(sorted(v for v in kokoro.voices.files if v.startswith(("af_", "am_", "bf_", "bm_")))))
        return
    job = json.loads(args.request.read_text(encoding="utf-8-sig"))
    voice = job.get("kokoroVoice", "af_heart")
    lang = "en-gb" if voice.startswith("b") else "en-us"
    speed = max(0.5, min(2.0, 1.0 + int(job.get("rate", 0)) * 0.1))
    volume = max(0, min(100, int(job.get("volume", 100)))) / 100
    rendered = []
    for text in chunks(job["text"]):
        write_state(args.data_dir, "generating", job["id"])
        audio, rate = kokoro.create(text, voice=voice, speed=speed, lang=lang)
        audio = np.asarray(audio, dtype=np.float32) * volume
        if args.output:
            rendered.append(audio)
        else:
            import sounddevice as sd
            write_state(args.data_dir, "speaking", job["id"])
            sd.play(audio, rate, blocking=True)
    if args.output:
        audio = np.concatenate(rendered)
        with wave.open(str(args.output), "wb") as fp:
            fp.setnchannels(1)
            fp.setsampwidth(2)
            fp.setframerate(rate)
            fp.writeframes((np.clip(audio, -1, 1) * 32767).astype("<i2").tobytes())

if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)

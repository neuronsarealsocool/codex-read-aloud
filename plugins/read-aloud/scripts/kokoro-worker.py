"""Offline CPU/CUDA synthesis and playback; supervised by reader.ps1."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import queue
import sys
import threading
import time
import wave

_dll_directories = []

def preload_cuda(ort):
    if os.name == 'nt':
        # cuDNN dynamically loads additional engines not listed by ORT's preloader.
        bins = sorted((Path(ort.__file__).parent.parent / 'nvidia').glob('*/bin'))
        for directory in bins:
            _dll_directories.append(os.add_dll_directory(str(directory)))
        os.environ['PATH'] = os.pathsep.join(map(str, bins)) + os.pathsep + os.environ.get('PATH', '')
    ort.preload_dlls(directory='')

def create_session(root, provider="auto"):
    import onnxruntime as ort
    options = ort.SessionOptions()
    options.log_severity_level = 3
    options.intra_op_num_threads = min(4, os.cpu_count() or 1)
    gpu_model = root / "kokoro-v1.0.onnx"
    if provider != "cpu" and gpu_model.exists() and "CUDAExecutionProvider" in ort.get_available_providers():
        try:
            preload_cuda(ort)
            session = ort.InferenceSession(str(gpu_model), options, providers=[
                ("CUDAExecutionProvider", {"cudnn_conv_algo_search": "DEFAULT"}),
                "CPUExecutionProvider",
            ])
            if "CUDAExecutionProvider" not in session.get_providers():
                raise RuntimeError("CUDA could not initialize")
            if provider == 'cuda':
                session.disable_fallback()
            return session
        except Exception as error:
            if provider == "cuda":
                raise
            print(f"CUDA unavailable; using CPU: {error}", file=sys.stderr)
    elif provider == "cuda":
        raise RuntimeError("CUDA runtime or full-precision model missing. Run setup-kokoro.py --gpu.")
    return ort.InferenceSession(str(root / "kokoro-v1.0.int8.onnx"), options, providers=["CPUExecutionProvider"])

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

def play_buffered(audio_chunks, on_start):
    """Generate ahead on one thread and keep one audio stream open for the job."""
    import sounddevice as sd
    pending = queue.Queue(maxsize=2)
    cancelled = threading.Event()

    def send(kind, value):
        while not cancelled.is_set():
            try:
                pending.put((kind, value), timeout=0.1)
                return
            except queue.Full:
                pass

    def produce():
        try:
            for audio, rate in audio_chunks:
                if cancelled.is_set():
                    return
                send('audio', (audio, rate))
            send('end', None)
        except Exception as error:
            send('error', error)

    producer = threading.Thread(target=produce, name='kokoro-prefetch', daemon=True)
    producer.start()
    stream = None
    writes = []
    underruns = 0
    try:
        while True:
            kind, value = pending.get()
            if kind == 'error':
                raise value
            if kind == 'end':
                break
            audio, rate = value
            if stream is None:
                stream = sd.OutputStream(samplerate=rate, channels=1, dtype='float32', blocksize=1024, latency='high')
                stream.start()
                on_start()
            elif rate != stream.samplerate:
                raise RuntimeError('Kokoro changed its sample rate during playback')
            started = time.perf_counter()
            underflowed = stream.write(audio)
            # Starting an empty device can flag the initial write; count later gaps.
            if writes and underflowed:
                underruns += 1
            writes.append({'started': started, 'finished': time.perf_counter()})
        if stream is not None:
            stream.stop()  # Drain the final buffered samples before the worker exits.
        return {'writes': writes, 'underruns': underruns}
    finally:
        cancelled.set()
        if stream is not None:
            stream.close()
        producer.join(timeout=1)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-dir", required=True, type=Path)
    parser.add_argument("--request", type=Path)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--provider", choices=["auto", "cpu", "cuda"], default="auto")
    args = parser.parse_args()
    # Explicit local paths; playback never downloads models or runtime files.
    import numpy as np
    from kokoro_onnx import Kokoro
    root = args.data_dir / "kokoro"
    session = create_session(root, args.provider)
    kokoro = Kokoro.from_session(session, str(root / "voices-v1.0.bin"))
    if args.check:
        print("Execution providers: " + ", ".join(session.get_providers()))
        print(json.dumps(sorted(v for v in kokoro.voices.files if v.startswith(("af_", "am_", "bf_", "bm_")))))
        return
    job = json.loads(args.request.read_text(encoding="utf-8-sig"))
    voice = job.get("kokoroVoice", "af_heart")
    lang = "en-gb" if voice.startswith("b") else "en-us"
    speed = max(0.5, min(2.0, 1.0 + int(job.get("rate", 0)) * 0.1))
    volume = max(0, min(100, int(job.get("volume", 100)))) / 100
    timings = []
    write_state(args.data_dir, "generating", job["id"])
    def synthesize():
        for text in chunks(job["text"]):
            started = time.perf_counter()
            audio, rate = kokoro.create(text, voice=voice, speed=speed, lang=lang)
            finished = time.perf_counter()
            timings.append({"generationSeconds": round(finished - started, 3), "audioSeconds": round(len(audio) / rate, 3), "started": started, "finished": finished})
            yield np.asarray(audio, dtype=np.float32) * volume, rate

    playback = None
    if args.output:
        rendered = []
        for audio, rate in synthesize():
            rendered.append(audio)
        audio = np.concatenate(rendered)
        with wave.open(str(args.output), "wb") as fp:
            fp.setnchannels(1)
            fp.setsampwidth(2)
            fp.setframerate(rate)
            fp.writeframes((np.clip(audio, -1, 1) * 32767).astype("<i2").tobytes())
    else:
        playback = play_buffered(synthesize(), lambda: write_state(args.data_dir, "speaking", job["id"]))
    (args.data_dir / "kokoro-runtime.json").write_text(json.dumps({"providers": session.get_providers(), "chunks": timings, "playback": playback}), encoding="utf-8")

if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)

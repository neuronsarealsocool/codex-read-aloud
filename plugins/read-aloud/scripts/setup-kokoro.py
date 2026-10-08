"""One-time online setup. Playback never downloads files."""
import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import urllib.request
import venv

FILES = {
    "kokoro-v1.0.int8.onnx": "ae315a79b623f244700e4afb9246c46a26066782e049ba174bf3ba433970ee9c",
    "voices-v1.0.bin": "bca610b8308e8d99f32e6fe4197e7ec01679264efed0cac9140fe9c29f1fbf7d",
}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-dir", type=Path, default=Path(os.environ["LOCALAPPDATA"]) / "CodexReadAloud")
    args = parser.parse_args()
    root = args.data_dir / "kokoro"
    root.mkdir(parents=True, exist_ok=True)
    runtime = root / "venv"
    python = runtime / "Scripts" / "python.exe"
    if not python.exists():
        venv.create(runtime, with_pip=True)
    subprocess.run([str(python), "-m", "pip", "install", "kokoro-onnx==0.6.1", "sounddevice==0.5.6"], check=True)
    for name, expected in FILES.items():
        target = root / name
        if target.exists():
            with target.open("rb") as fp:
                if hashlib.file_digest(fp, "sha256").hexdigest() == expected:
                    continue
        temp = target.with_suffix(target.suffix + ".download")
        print(f"Downloading {name}", flush=True)
        urllib.request.urlretrieve(f"https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.1/{name}", temp)
        with temp.open("rb") as fp:
            actual = hashlib.file_digest(fp, "sha256").hexdigest()
        if actual != expected:
            temp.unlink()
            raise RuntimeError(f"Checksum mismatch for {name}")
        temp.replace(target)
    subprocess.run([str(python), str(Path(__file__).with_name("kokoro-worker.py")), "--data-dir", str(args.data_dir), "--check"], check=True)
    print("Kokoro installed and verified. Select it with reader.ps1 -Mode Engine -Value kokoro.")

if __name__ == "__main__":
    main()

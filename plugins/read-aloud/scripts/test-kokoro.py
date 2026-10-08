"""Run with the installed Kokoro venv Python after setup. No audible playback."""
import json
import os
from pathlib import Path
import runpy
import socket
import subprocess
import sys
import tempfile
import time
import wave

scripts = Path(__file__).parent
data = Path(os.environ["LOCALAPPDATA"]) / "CodexReadAloud"
test = Path(tempfile.mkdtemp(prefix="CodexKokoroTest-"))

def blocked(*args, **kwargs):
    raise AssertionError("Offline synthesis attempted a network connection")

# Generate actual speech while denying Python socket connections.
socket.socket.connect = blocked
socket.create_connection = blocked
for voice in ("af_heart", "bf_emma"):
    request = test / "request.json"
    request.write_text(json.dumps({"id": "offline-test", "text": "Two plus two is four. Kokoro speech runs entirely on this computer.", "kokoroVoice": voice, "volume": 100, "rate": 0}), encoding="utf-8")
    output = test / f"{voice}.wav"
    sys.argv = ["kokoro-worker.py", "--data-dir", str(data), "--request", str(request), "--output", str(output)]
    runpy.run_path(str(scripts / "kokoro-worker.py"), run_name="__main__")
    with wave.open(str(output), "rb") as fp:
        assert fp.getframerate() == 24000
        assert fp.getnframes() > 24000
        assert any(fp.readframes(fp.getnframes())), "Empty speech audio"

# Reuse installed runtime through a junction, but keep test settings isolated.
subprocess.run(["cmd.exe", "/c", "mklink", "/J", str(test / "kokoro"), str(data / "kokoro")], check=True, capture_output=True)
(test / "settings.json").write_text(json.dumps({"enabled": True, "voice": "Microsoft Zira Desktop", "rate": 0, "volume": 0, "skipCode": True, "maxCharacters": 20000, "narrateProgress": True, "engine": "kokoro", "kokoroVoice": "af_heart"}), encoding="utf-8")
reader = ["powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", str(scripts / "reader.ps1")]
payload = json.dumps({"hook_event_name": "Stop", "session_id": "kokoro-test", "turn_id": "1", "last_assistant_message": "This is a long cancellation test. " * 100})
try:
    started = time.monotonic()
    # Do not capture inherited worker handles: waiting on those pipes waits for
    # playback as well as the hook. The Windows test checks the JSON hook output.
    subprocess.run(reader + ["-Mode", "Hook", "-DataDir", str(test)], input=payload, encoding="utf-8", stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    assert time.monotonic() - started < 10
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        state_path = test / "playback.json"
        if state_path.exists() and json.loads(state_path.read_text())["state"] == "speaking":
            break
        time.sleep(0.1)
    else:
        raise AssertionError("Kokoro did not reach audio playback")
    started = time.monotonic()
    subprocess.run(reader + ["-Mode", "Stop", "-DataDir", str(test)], check=True, capture_output=True)
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        if json.loads(state_path.read_text())["state"] == "idle":
            break
        time.sleep(0.1)
    else:
        raise AssertionError("Stop did not cancel Kokoro promptly")
    assert not (test / "kokoro-error.txt").exists(), "Kokoro fell back to Windows"
    assert not (test / "last-error.txt").exists(), "Worker failed"
finally:
    subprocess.run(reader + ["-Mode", "Stop", "-DataDir", str(test)], capture_output=True)
print("PASS: American and British synthesis with network connections denied, nonempty audio, prompt completion hook, real Kokoro playback and cancellation without Windows fallback.")
print(f"Test data: {test}")

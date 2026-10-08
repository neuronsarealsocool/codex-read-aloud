"""Run with the installed Kokoro venv Python after setup. No audible playback."""
import argparse
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
parser = argparse.ArgumentParser()
parser.add_argument('--require-cuda', action='store_true')
args = parser.parse_args()
data = Path(os.environ["LOCALAPPDATA"]) / "CodexReadAloud"
test = Path(tempfile.mkdtemp(prefix="CodexKokoroTest-"))

def blocked(*args, **kwargs):
    raise AssertionError("Offline synthesis attempted a network connection")

# Generate actual speech while denying Python socket connections.
socket.socket.connect = blocked
socket.create_connection = blocked
# A failed producer must propagate its error rather than leave playback waiting.
worker = runpy.run_path(str(scripts / 'kokoro-worker.py'))
def failed_synthesis():
    raise RuntimeError('test synthesis failure')
    yield
try:
    worker['play_buffered'](failed_synthesis(), lambda: None)
    raise AssertionError('Producer failure was ignored')
except RuntimeError as error:
    assert str(error) == 'test synthesis failure'
for voice in ("af_heart", "bf_emma"):
    request = test / "request.json"
    request.write_text(json.dumps({"id": "offline-test", "text": "Two plus two is four. Kokoro speech runs entirely on this computer.", "kokoroVoice": voice, "volume": 100, "rate": 0}), encoding="utf-8")
    output = test / f"{voice}.wav"
    sys.argv = ["kokoro-worker.py", "--data-dir", str(data), "--request", str(request), "--output", str(output)]
    runpy.run_path(str(scripts / "kokoro-worker.py"), run_name="__main__")
    if args.require_cuda:
        assert 'CUDAExecutionProvider' in json.loads((data / 'kokoro-runtime.json').read_text())['providers'], 'GPU test fell back to CPU'
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
    # Also test natural completion, which follows a different supervisor path.
    paragraph = "Chevrolet is an American car brand founded in 1911 by racing driver Louis Chevrolet and businessman William Durant. Three plus three is six. Four plus four is eight."
    subprocess.run(reader + ["-Mode", "Test", "-Text", paragraph, "-DataDir", str(test)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        if not list(test.glob("*.stderr")) and not list(test.glob("*.json")):
            break
        queued = [p for p in test.glob("*.json") if len(p.stem) == 32]
        if not queued:
            break
        time.sleep(0.1)
    else:
        raise AssertionError("Natural Kokoro completion timed out")
    assert not (test / "kokoro-error.txt").exists(), "Completed Kokoro fell back to Windows"
    if args.require_cuda:
        runtime = json.loads((test / 'kokoro-runtime.json').read_text())
        assert 'CUDAExecutionProvider' in runtime['providers'], 'Playback fell back to CPU'
        assert len(runtime['chunks']) == 3 and len(runtime['playback']['writes']) == 3, 'Playback lost or duplicated a sentence'
        assert runtime['chunks'][1]['finished'] < runtime['playback']['writes'][0]['finished'], 'Second sentence was not generated during first-sentence playback'
        assert runtime['playback']['underruns'] == 0, 'Audio stream ran out of buffered samples between sentences'
finally:
    subprocess.run(reader + ["-Mode", "Stop", "-DataDir", str(test)], capture_output=True)
print("PASS: offline American/British synthesis, producer error propagation, buffered multi-sentence playback, completion and cancellation without Windows fallback.")
print(f"Test data: {test}")

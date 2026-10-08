"""Measure local model loading and speech generation without playback."""
import argparse
from collections import Counter
import json
import importlib
import os
from pathlib import Path
import time

parser = argparse.ArgumentParser()
parser.add_argument('--provider', choices=['cpu', 'cuda'], default='cpu')
parser.add_argument('--model', default='kokoro-v1.0.int8.onnx')
parser.add_argument('--profile', action='store_true')
args = parser.parse_args()
started = time.perf_counter()
import onnxruntime as ort
from kokoro_onnx import Kokoro
root = Path(os.environ['LOCALAPPDATA']) / 'CodexReadAloud' / 'kokoro'
options = ort.SessionOptions()
options.intra_op_num_threads = min(4, os.cpu_count() or 1)
options.enable_profiling = args.profile
options.profile_file_prefix = str(root / 'benchmark-profile')
if args.provider == 'cuda':
    importlib.import_module('kokoro-worker').preload_cuda(ort)
providers = [('CUDAExecutionProvider', {'cudnn_conv_algo_search': 'DEFAULT'}), 'CPUExecutionProvider'] if args.provider == 'cuda' else ['CPUExecutionProvider']
session = ort.InferenceSession(str(root / args.model), options, providers=providers)
if args.provider == 'cuda' and 'CUDAExecutionProvider' not in session.get_providers():
    raise RuntimeError('CUDA did not initialize; refusing a misleading GPU benchmark')
session.disable_fallback()
kokoro = Kokoro.from_session(session, str(root / 'voices-v1.0.bin'))
loaded = time.perf_counter()
results = []
for text in ['This is a short spoken progress update.', 'Chevrolet is an American car brand founded in 1911 by racing driver Louis Chevrolet and businessman William C. Durant.'] * 2:
    begin = time.perf_counter()
    audio, rate = kokoro.create(text, voice='af_heart', lang='en-us')
    if args.provider == 'cuda' and 'CUDAExecutionProvider' not in session.get_providers():
        raise RuntimeError('CUDA failed during synthesis; refusing a misleading GPU benchmark')
    seconds = time.perf_counter() - begin
    results.append({'generation_seconds': round(seconds, 3), 'audio_seconds': round(len(audio) / rate, 3), 'real_time_factor': round(seconds / (len(audio) / rate), 3)})
report = {'provider': args.provider, 'model': args.model, 'providers': session.get_providers(), 'startup_seconds': round(loaded - started, 3), 'samples': results}
if args.profile:
    profile = json.loads(Path(session.end_profiling()).read_text())
    report['executed_nodes_by_provider'] = dict(Counter(event.get('args', {}).get('provider') for event in profile if event.get('args', {}).get('provider')))
print(json.dumps(report, indent=2))

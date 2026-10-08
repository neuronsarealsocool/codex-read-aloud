# Codex Read Aloud for Windows

Read completed Codex answers aloud using offline Windows speech voices, with optional narration of visible progress updates and buttons underneath answers.

**Windows only. No speech API key, external audio service, or subscription required.** Codex itself still requires its usual account/access. This is an independent community plugin.

## Install

You need Windows, Git, and a current Codex CLI with plugin and lifecycle-hook support. In PowerShell:

```powershell
codex plugin marketplace add https://github.com/neuronsarealsocool/codex-read-aloud.git
codex plugin add read-aloud@codex-read-aloud
```

Restart Codex. Review and trust the plugin's **SessionStart** and **Stop** hooks when prompted. In the CLI, `/hooks` opens hook review. Installation does not automatically approve hooks. In supported desktop clients, confirm the plugin is enabled in the Plugins directory.

Try asking: **“Use Read Aloud to test speech, then show the reading controls.”** Then ask **“1+1”** to test automatic completion playback. A manual test alone does not prove the Stop hook is active.

If `codex` is not found, install or expose the Codex CLI on PATH first. Plugin support and hook review UI vary with client version. See [official plugin packaging documentation](https://developers.openai.com/plugins/build/plugins).

## Features

### Additional Windows voices (1.4)

George, Hazel, and Susan now have selection buttons. The modern Windows speech API also exposes installed voices such as Australian Catherine and James and American Mark, without changing the registry. Ask for all voices and select an exact listed name. George and Susan use this modern API; the Hazel button uses its classic desktop voice. Voice selection switches to the Windows engine and preserves your automatic-reading setting.

These are fast legacy Windows voices. Narrator's separately packaged natural voices are not supported by this integration. On machines without the British voice pack, those buttons report the missing voice; they do not download it automatically. Speech uses memory streams and remains offline. Stop can cancel both synthesis and playback.

### Optional Kokoro neural voices (1.3)

Kokoro runs completely offline after one-time setup. Install Python 3.12 and, from a clone of this repository, run:

```powershell
python plugins/read-aloud/scripts/setup-kokoro.py
powershell.exe -NoProfile -ExecutionPolicy Bypass -File plugins/read-aloud/scripts/reader.ps1 -Mode Engine -Value kokoro
```

Alternatively ask Codex to use the installed Read Aloud plugin's `scripts/setup-kokoro.py` with Python 3.12 and select the Kokoro engine. Setup downloads about 142 MB of checksum-verified model/voice files, plus Python packages, into `%LOCALAPPDATA%\CodexReadAloud\kokoro`. It does not bundle these files into the plugin repository. Python must remain installed because the local environment depends on it.

The default Kokoro voice is **af_heart** (American English). Select **bf_emma** for British English using the Kokoro Emma button, or ask for all installed voices. Windows voice buttons switch back to Windows speech. Existing speed, Stop, automatic-reading, and progress controls work with either engine. Kokoro may take several seconds to load and generate the first audio and speaks in short chunks. On failure it falls back to Windows and records `kokoro-error.txt`. An abrupt process termination may leave a transient error file.

For an NVIDIA GPU, run setup with `--gpu` using Python 3.12:

```powershell
python plugins/read-aloud/scripts/setup-kokoro.py --gpu
```

This installs ONNX Runtime GPU 1.24.4 with CUDA 12/cuDNN libraries in the plugin's Python environment and downloads a checksum-verified full-precision model. Allow roughly 2 GB for downloads plus installation space. Playback remains offline. The worker automatically prefers CUDA when installed and falls back to the CPU int8 model if CUDA cannot initialize. `kokoro-runtime.json` records the actual providers and completed chunk timings. Model loading still happens for each speech request; GPU acceleration improves generation but does not eliminate startup time. Re-running setup preserves an existing GPU installation. Windows voices remain available.

Run the venv's Python with `plugins/read-aloud/scripts/benchmark-kokoro.py` for a CPU baseline or add `--provider cuda --model kokoro-v1.0.onnx` for GPU timings without audio playback. The GPU benchmark refuses to report CPU fallback as GPU performance.

Upstream: [Kokoro ONNX](https://github.com/thewh1teagle/kokoro-onnx) (MIT wrapper, Apache-2.0 model weights). Its dependencies have their own licences, including eSpeak NG; they are installed separately by setup.

- Automatically reads the final answer through the Stop lifecycle hook.
- Narrates meaningful visible progress updates when the assistant calls the bundled Narrate command. This is best-effort; there is no commentary lifecycle hook.
- Offers Read answer, Stop, Auto on/off, speed, voice, status, and Progress on/off controls.
- Uses Microsoft Zira by default, with installed-voice selection and normal speed.
- Skips fenced code, raw URLs, and control markup; reads Markdown link labels. Short numeric answers are preserved.
- Caps spoken answers at 20,000 characters. New speech replaces older playback across local chats.

The buttons require a Codex desktop client with the inline visualization surface, its host follow-up bridge, and the visualize skill. They send a new chat prompt, so commands have chat response latency. They do not add buttons to the built-in icon row. CLI users can control speech with prompts or PowerShell instead. Button inclusion also depends on the assistant following the SessionStart instructions.

Progress narration reads only updates already visible in the chat. It does not expose or read private model reasoning.

## Everyday controls

Ask Codex:

- “Stop reading.”
- “Turn read aloud off” or “Turn read aloud on.”
- “Read faster” or “Reset reading speed.”
- “List reading voices.”
- “Turn spoken progress off” or “Turn spoken progress on.”
- “Read the previous answer.”

Automatic reading and progress narration are enabled by default. Turning automatic reading off silences both; progress can also be toggled separately.

## Local data and permissions

Audio is generated locally using Windows PowerShell 5.1 and `System.Speech`. Hooks launch a hidden speech worker. No network requests are made by the speech code.

Settings and playback metadata live in `%LOCALAPPDATA%\CodexReadAloud`. Temporary request files contain the text being spoken and are deleted after playback; an interrupted process can leave a request file behind. The plugin does not scan chat transcript files. Errors are written to `last-error.txt` in the same directory.

Review `plugins/read-aloud/hooks/hooks.json` and `scripts/reader.ps1` before trusting the hooks. Changed hook commands require renewed trust review.

## Troubleshooting

- **Manual speech works but answers are silent:** check the plugin is enabled and the Stop hook is trusted; restart Codex after installation.
- **No buttons:** check your client supports inline visualizations and the visualize skill is available. Prompt/PowerShell controls work independently.
- **No progress speech:** ensure automatic reading and progress narration are on. The assistant must call Narrate after a visible update.
- **Voice unavailable:** ask for installed voices and select one. Zira and David buttons are shortcuts for those Windows desktop voices, when installed.
- **Speech stops early:** newer updates and answers replace older playback. Very long answers are truncated at the configured limit.

## Update or uninstall

```powershell
codex plugin marketplace upgrade codex-read-aloud
codex plugin add read-aloud@codex-read-aloud
```

Restart Codex after updating. To uninstall:

```powershell
codex plugin remove read-aloud@codex-read-aloud
```

User settings remain in `%LOCALAPPDATA%\CodexReadAloud` for reinstallation.

## Development and tests

The distributable plugin lives in `plugins/read-aloud`; the repository marketplace is `.agents/plugins/marketplace.json`.

```powershell
npm install
npm test
npm run test:speech
```

The controls test covers all 18 buttons using installed Google Chrome via Playwright and a mocked Codex host bridge. The Windows speech test uses a separate temporary data directory, volume zero, and checks cleanup, completion, deduplication, stopping, settings, speed, and progress narration. With the British voices installed, run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File plugins/read-aloud/scripts/test-windows-voices.ps1` to verify modern Windows playback, cancellation, and preservation of the automatic-off setting.

After Kokoro setup, run its installed venv Python with `plugins/read-aloud/scripts/test-kokoro.py`. This generates American and British audio while denying Python network connections and checks real muted playback and cancellation with isolated settings. Tests leave their temporary directories for inspection.

After GPU setup, add `--require-cuda` to that test command to verify both synthesis and playback actually retain CUDA rather than silently using CPU fallback.

Current version: **1.5.0**. Licensed under MIT; see [LICENSE](LICENSE).

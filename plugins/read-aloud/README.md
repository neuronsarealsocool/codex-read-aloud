# Read Aloud 1.2.0

Offline Windows speech for Codex completed answers, with optional visible progress narration and inline controls.

See the [repository README](https://github.com/neuronsarealsocool/codex-read-aloud#readme) for installation, hook trust review, requirements, usage, tests, and troubleshooting.

Direct controls from this plugin directory, using Windows PowerShell:

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ./scripts/reader.ps1 -Mode Status
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ./scripts/reader.ps1 -Mode Stop
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ./scripts/reader.ps1 -Mode Off
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ./scripts/reader.ps1 -Mode On
```

Settings and playback metadata persist in `%LOCALAPPDATA%\CodexReadAloud`. Speech is local and uses no API key. Automatic playback requires a trusted Stop lifecycle hook. Buttons require the desktop visualization surface and follow-up bridge. Progress narration requires assistant calls to Narrate; it is best-effort and reads visible updates only.

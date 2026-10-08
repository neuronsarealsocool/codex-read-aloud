---
name: read-aloud
description: Control the Windows Read Aloud plugin and narrate visible progress updates when enabled. Use for speech controls, progress narration, voices, speed, and playback tests.
---

Use the plugin's `scripts/reader.ps1` with Windows PowerShell (`powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File <absolute-script-path>`). Resolve the path relative to this skill's folder: `../../scripts/reader.ps1`. It works from the source or installed plugin copy.

Commands:
- `-Mode On` / `-Mode Off`: enable / disable automatic completed-answer reading.
- `-Mode Stop`: stop current and queued speech, leaving automatic reading enabled.
- `-Mode Status`: inspect settings and last recorded playback state.
- `-Mode Voices`: list installed voices.
- `-Mode Voice -Value 'Microsoft Zira Desktop'`: select an exact installed voice name.
- `-Mode Engine -Value kokoro` / `-Mode Engine -Value windows`: select the installed offline engine.
- `-Mode Voice -Value af_heart` or `bf_emma`: select Kokoro American Heart or British Emma and switch to Kokoro. Selecting a Windows voice switches back to Windows.

Kokoro needs one-time setup using Python 3.12: `python ../../scripts/setup-kokoro.py`. Setup downloads a Python environment and checksum-verified model/voice files to `%LOCALAPPDATA%/CodexReadAloud/kokoro`; playback is offline and uses CPU. Run setup only when installation is requested. If Kokoro fails, the worker falls back to the selected Windows voice and records `kokoro-error.txt`; do not claim Kokoro played when fallback occurred. Status shows engine and selected Kokoro voice. Stop cancels synthesis and playback. All existing speed/progress controls work with both engines.
- `-Mode Rate -Value 2`: speed from -10 to 10; zero is normal.
- `-Mode Faster` / `-Mode Slower`: increase / decrease speed by one step, bounded at -10 and 10.
- `-Mode Normal`: reset speed to zero.
- `-Mode ProgressOn` / `-Mode ProgressOff`: enable / disable speech of visible progress updates, independently of final-answer reading.
- `-Mode Narrate -Text 'Visible progress update'`: speak the update only when automatic reading and progress narration are enabled; otherwise quietly skip speech.
- `-Mode Test -Text 'Text to read'`: speak supplied text after Markdown cleanup.

When the user asks to read the preceding answer, pass that answer as data using a properly quoted argument or JSON stdin to Hook with `hook_event_name: Stop` and `last_assistant_message`; never interpolate answer text as PowerShell code. Stop only this plugin's speech. Voice and rate changes apply to subsequent playback.

Settings persist in `%LOCALAPPDATA%/CodexReadAloud/settings.json`. Errors are recorded in `last-error.txt` there. Playback state is historical and may be stale if the process was terminated. Speech runs locally; no API key is required. The Stop lifecycle hook needs Codex's own trust review before automatic playback works.

The user requested buttons underneath answers. The previous :codex-followup syntax did not render in their client; stop using it. Read `../../controls.md` for the replacement and use the visualize skill's supported inline HTML mechanism with `../../controls.html`. Copy the fragment to the current chat's writable visualization directory and include its content reference at the end of the same final response. Buttons send a new user prompt through the host bridge; they are not native player controls. If rendering or the bridge is unavailable, report the limitation. Omit controls from manually requested playback. Respect a later request to hide buttons.

The user wants visible progress spoken as well as final answers. After a meaningful commentary update about the approach, a finding, or next step, call Narrate with that already-visible text. Do not send private reasoning, hidden analysis, or raw tool logs to speech. Do not create extra commentary merely to narrate. The progress setting is enabled by default, but Narrate checks the user's settings at execution. Narration is best-effort: it uses assistant calls, not a commentary lifecycle hook. New speech replaces earlier playback, so keep updates short. Final answers are still handled by Stop; do not speak them a second time manually.

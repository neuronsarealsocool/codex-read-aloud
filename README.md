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

The controls test uses installed Google Chrome via Playwright and a mocked Codex host bridge. The Windows speech test uses a separate temporary data directory, volume zero, and checks cleanup, completion, deduplication, stopping, settings, speed, and progress narration.

Current version: **1.2.0**. Licensed under MIT; see [LICENSE](LICENSE).

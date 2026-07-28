# Quill (Citedy fork)

Menu-bar meeting recorder for macOS: mic + system audio as two tracks, then
transcription and a GPT summary in a native result window.

Based on [digimata/quill](https://github.com/digimata/quill), extended for
Russian meetings, OpenAI Whisper, and a proper post-stop UI.

## Features

- **Menu bar app** — no Dock icon (`LSUIElement`)
- **Dual-track recording** — `mic.caf` (you) + `system.caf` (them)
- **OpenAI Whisper** transcription (`whisper-1`, language configurable, default `ru`)
- **Result window** on Stop:
  - spinner while transcribing / summarizing
  - full transcript
  - **gpt-4o-mini** summary + key points
  - copy all / open in Mail / open session folder
- **CLI**: `quill rec`, `quill stop`, `quill show`, `quill doctor`

## Requirements

- macOS 15+
- Apple Silicon recommended
- OpenAI API key (`OPENAI_API_KEY`)

## Install (DMG)

1. Open `Quill-1.1.0.dmg` from [Releases](../../releases)
2. Drag **Quill.app** to Applications
3. Launch Quill (menu bar shows **Quill**)
4. Put your key in `~/.config/quill/env`:

```sh
mkdir -p ~/.config/quill
cat > ~/.config/quill/env <<'EOF'
OPENAI_API_KEY=sk-...
EOF
chmod 600 ~/.config/quill/env
```

5. Optional config `~/.config/quill/config.json`:

```json
{
  "recordings_dir": "~/Downloads/Recordings",
  "transcription": {
    "enabled": true,
    "engine": "openai",
    "model": "whisper-1",
    "language": "ru",
    "api_key_env": "OPENAI_API_KEY"
  }
}
```

## Build from source

```sh
git clone https://github.com/nttylock/citedy-quill.git
cd citedy-quill
swift build -c release
./scripts/package-app.sh
./scripts/package-dmg.sh
```

Produces:

- `dist/Quill.app`
- `dist/Quill-1.1.0.dmg`

## Usage

1. Start **Quill** (menu bar label **Quill**)
2. **Start recording** → grant mic + system audio if prompted
3. **Stop recording** → result window opens automatically
4. Wait for transcript + summary → copy or email

Sessions: `~/Downloads/Recordings/<yyyy.MM.dd-HHmm>/` (configurable)

| File | Contents |
|---|---|
| `mic.caf` / `system.caf` | audio tracks |
| `meta.json` | timestamps / offsets |
| `transcript.json` / `transcript.md` | transcript |
| `summary.md` | gpt-4o-mini summary |
| `transcribe.log` | pipeline log |

## CLI

```sh
quill                 # menu-bar daemon
quill doctor          # permissions + API key
quill rec             # start recording (daemon must be running)
quill stop            # stop + transcribe
quill show            # show control window
quill quit-daemon
quill install --launch-at-login
```

## Privacy note

Unlike the original on-device Parakeet path, **this fork uploads audio to OpenAI**
for Whisper and sends transcript text to **gpt-4o-mini** for summarization.
Keep that in mind for sensitive meetings.

## License

Same as upstream digimata/quill unless otherwise noted in the original repo.
Citedy fork changes are provided as-is for personal / product use.

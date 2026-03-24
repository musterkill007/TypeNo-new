# TypeNo

A minimal macOS voice input app. Press Control, speak, done.

TypeNo captures your voice, transcribes it locally, and pastes the result into whatever app you were using — all in under a second.

## How It Works

1. **Short-press Control** to start recording
2. **Short-press Control** again to stop
3. Text is automatically transcribed and pasted into your active app (also copied to clipboard)

That's it. No windows, no settings, no accounts.

## Install

### Prerequisites

- macOS 14+
- [coli](https://github.com/nicepkg/coli) for local speech recognition:

```bash
npm i -g @anthropic-ai/coli
```

### Build from Source

```bash
git clone https://github.com/nicepkg/TypeNo.git
cd TypeNo
scripts/generate_icon.sh
scripts/build_app.sh
```

The app will be at `dist/TypeNo.app`. Move it to `/Applications/` for persistent permissions.

### First Launch

TypeNo needs two permissions (one-time):
- **Microphone** — to capture your voice
- **Accessibility** — to paste text into apps

The app will guide you through granting these on first launch.

## Usage

| Action | Trigger |
|---|---|
| Start/stop recording | Short-press `Control` (< 300ms, no other keys) |
| Start/stop recording | Menu bar → Record (`⌃R`) |
| Transcribe a file | Drag `.m4a`/`.mp3`/`.wav`/`.aac` to the menu bar icon |
| Quit | Menu bar → Quit (`⌘Q`) |

## Design Philosophy

TypeNo does one thing: voice → text → paste. No extra UI, no preferences, no configuration. The fastest way to type is to not type at all.

## Internationalization

- [中文说明](README_CN.md)
- [日本語の説明](README_JP.md)

## License

MIT

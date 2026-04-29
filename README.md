# TypeNo

[中文](README_CN.md)

**A free, open source, privacy-first voice input tool for macOS.**

![TypeNo hero image](assets/hero.webp)

A minimal macOS voice input app. TypeNo captures your voice, transcribes it locally, and pastes the result into whatever app you were using — all in under a second.

Official website: [https://typeno.com](https://typeno.com)

Special thanks to [marswave ai's coli project](https://github.com/marswaveai/coli) for powering local speech recognition.

## How It Works

1. **Short-press Control** to start recording
2. **Short-press Control** again to stop
3. Text is automatically transcribed and pasted into your active app (also copied to clipboard)
4. While recording, TypeNo lives around the MacBook notch: a compact recording dot and timer stay beside the notch, and the preview expands downward when you hover or click
5. After you stop, TypeNo runs a final full-file transcription before pasting, so the inserted text is based on the complete recording

That's it. No windows, no settings, no accounts.

## Notch Island Preview

TypeNo now uses a notch-attached overlay inspired by Dynamic Island:

- **Idle history entry:** when you are not recording, click the compact history icon beside the notch to reopen recent transcripts and copy them again.
- **Recording status:** while recording, the notch area shows a compact recording indicator and elapsed time.
- **Expandable preview:** hover or click the notch island to expand a transcription preview. Long text wraps and scrolls inside the panel.
- **Fullscreen-friendly:** when another app is in fullscreen, TypeNo hides the idle floating history entry by default. Starting a recording still shows the recording island.
- **Lower heat:** realtime preview is started only when the preview is expanded; final transcription still uses the full audio after recording stops.

## Install

### Option 1 — Download the App

- [Download TypeNo for macOS](https://github.com/marswaveai/TypeNo/releases/latest)
- Download the latest `TypeNo.app.zip`
- Unzip it
- Move `TypeNo.app` to `/Applications`
- Open TypeNo

TypeNo is signed and notarized by Apple — it should open without any warnings.

### Install the speech engine

TypeNo uses [coli](https://github.com/marswaveai/coli) for local speech recognition.

**Prerequisites:**
- [Node.js](https://nodejs.org) (LTS recommended — install directly from nodejs.org for best compatibility)
- [ffmpeg](https://ffmpeg.org) — required for audio conversion: `brew install ffmpeg`

```bash
npm install -g @marswave/coli
```

If Coli is missing, TypeNo will show an in-app setup prompt with the install command.

> **Node 24+:** If you get a `sherpa-onnx-node` error, build from source:
> ```bash
> npm install -g @marswave/coli --build-from-source
> ```

### First Launch

TypeNo needs two one-time permissions:
- **Microphone** — to capture your voice
- **Accessibility** — to paste text into apps

The app will guide you through granting these on first launch.

### Troubleshooting: Coli Model Download Fails

The speech model is downloaded from GitHub. If GitHub is inaccessible in your network, the download will fail.

**Fix:** Enable **TUN mode** (also called Enhanced Mode) in your proxy tool to ensure all system-level traffic is routed correctly. Then retry the install:

```bash
npm install -g @marswave/coli
```

### Troubleshooting: Accessibility Permission Not Working

Some users find that enabling TypeNo in **System Settings → Privacy & Security → Accessibility** has no effect — a known macOS bug. The fix:

1. Select **TypeNo** in the list
2. Click **−** to remove it
3. Click **+** and re-add TypeNo from `/Applications`

![Accessibility permission fix](assets/accessibility-fix.gif)

### Option 2 — Build from Source

```bash
git clone https://github.com/marswaveai/TypeNo.git
cd TypeNo
scripts/generate_icon.sh
scripts/build_app.sh
```

The app will be at `dist/TypeNo.app`. Move it to `/Applications/` for persistent permissions.

## Usage

| Action | Trigger |
|---|---|
| Start/stop recording | Short-press `Control` (< 300ms, no other keys) |
| Start/stop recording | Menu bar → Record |
| Expand recording preview | Hover or click the notch island while recording |
| Reopen transcript history | Click the compact history entry beside the notch while idle |
| Watch incremental transcription | Expand the notch preview while recording; final paste still uses full-file transcription |
| Choose microphone | Menu bar → Microphone → Automatic / specific device |
| Transcribe a file | Drag `.m4a`/`.mp3`/`.wav`/`.aac` to the menu bar icon |
| Check for updates | Menu bar → Check for Updates... |
| Quit | Menu bar → Quit (`⌘Q`) |

## Design Philosophy

TypeNo does one thing: voice → text → paste. No extra UI, no preferences, no configuration. The fastest way to type is to not type at all.

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=marswaveai/TypeNo&type=Date)](https://star-history.com/#marswaveai/TypeNo&Date)

## License

GNU General Public License v3.0

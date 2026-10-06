# TIDAL Downloader for macOS

A native macOS front end for tidal-dl-ng, written in Swift and AppKit with the macOS 26 Liquid Glass design. It replaces the Qt window and keeps the same features: search (or paste a TIDAL link), browse your playlists, mixes and favorites, expand albums, artists, playlists and mixes, filter and sort results, a download queue with pause and resume, cover art, a log, and every preference from the Qt settings dialog.

The downloading is still done by the Python code in `tidal_dl_ng`. The app starts `python -m tidal_dl_ng.bridge` (see [`tidal_dl_ng/bridge.py`](../tidal_dl_ng/bridge.py)) and talks to it with newline-delimited JSON over stdin/stdout.

## Requirements

- macOS 26 (Tahoe) or later
- Xcode 26 command line tools (Swift 6)
- Python 3.12
- FFmpeg, for FLAC extraction and video conversion (`brew install ffmpeg`)

## Build

From the repository root:

```sh
python3.12 -m venv .venv
.venv/bin/pip install -e .
macos/build.sh             # builds macos/build/TIDAL Downloader.app
macos/build.sh --install   # also copies it to /Applications
```

The app runs the engine from this checkout's `.venv`, so keep the repository where you built it.

## Lossless audio

TIDAL now limits device-link logins to AAC 320 kbps for most tracks (see [python-tidal#404](https://github.com/EbbLabs/python-tidal/issues/404)). To download FLAC, choose **TIDAL Downloader → Sign In with Browser for Lossless…**. TIDAL's login page opens inside the app and sign-in finishes automatically.

## Differences from the Qt GUI

- Search results show up page by page as they arrive.
- Playlists load in parallel, about 5× faster for large libraries.
- If the configured FFmpeg path doesn't exist, the usual install locations are tried instead.
- A failed update check no longer reports a fake `v0.0.0` update.
- Settings save as soon as you change them.

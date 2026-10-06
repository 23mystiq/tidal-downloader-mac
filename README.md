# TIDAL Downloader for macOS

A native macOS app for downloading music and videos from TIDAL, up to Hi-Res Lossless FLAC (24-bit, 192 kHz). Built with Swift and AppKit for macOS 26 Tahoe, in Apple's Liquid Glass design.

The downloading engine is [tidal-dl-ng](https://pypi.org/project/tidal-dl-ng/) by **Robert Honz ([exislow](https://github.com/exislow))**. This project adds a new macOS interface on top of it, along with a few engine fixes. See [Credits](#credits).

**You need a paid TIDAL plan.**

## Features

- **Search** for artists, albums, tracks, videos and playlists, or paste a TIDAL link. Results appear as they arrive.
- **Browse your library:** your playlists, mixes and favorites are in the sidebar, with artwork.
- **Expand anything:** open an album, artist, playlist or mix right in the results to see what's inside.
- **Filter and sort** every column. Filters accept regular expressions.
- **Download queue** with pause and resume, live progress, and cover art for whatever you select.
- **Lossless sign-in:** sign in through TIDAL's own login page, inside the app, to get FLAC instead of AAC.
- **All the tidal-dl-ng options:** file naming templates, lyrics, embedded covers, playlist files, FFmpeg FLAC extraction and video conversion.
- **Feels like a Mac app:** glass sidebar and inspector, unified toolbar, keyboard shortcuts (⌘F search, ⌘D download, ⌘R reload, ⌘, settings), dark mode.

## Install

Requirements: macOS 26 or later, Xcode 26 Command Line Tools, Python 3.12, and [FFmpeg](https://ffmpeg.org) for FLAC extraction.

```sh
git clone https://github.com/23mystiq/tidal-downloader-mac.git
cd tidal-downloader-mac
python3.12 -m venv .venv
.venv/bin/pip install -e .
macos/build.sh --install
```

This copies **TIDAL Downloader** into Applications. The app runs the engine from the folder you cloned, so keep that folder where it is.

## Lossless audio

TIDAL now gives AAC 320 kbps instead of FLAC to the "device link" login that tidal-dl-ng uses ([details](https://github.com/EbbLabs/python-tidal/issues/404)). To download FLAC, choose **TIDAL Downloader → Sign In with Browser for Lossless…**. Most FLAC streams come packed in MP4, so keep **Settings → General → Extract FLAC** on and FFmpeg installed.

## How it works

```
TIDAL Downloader.app (Swift/AppKit)  ⇄  JSON over stdin/stdout  ⇄  python -m tidal_dl_ng.bridge  →  tidal-dl-ng engine
```

- `macos/` is the Swift package for the app; `macos/build.sh` turns it into an `.app` bundle.
- `tidal_dl_ng/bridge.py` is a headless backend that runs tidal-dl-ng's search, library, queue, download and settings logic.
- Everything else in `tidal_dl_ng/` is the tidal-dl-ng engine. Its command line tool (`tidal-dl-ng`) and Qt GUI (`tidal-dl-ng-gui`) still work too; see the [original documentation](docs/ORIGINAL_README.md).

## Changes to the engine

- **Search fixed:** TIDAL now repeats its "top hit" on every page of search results, which crashed tidal-dl-ng's search.
- **Lossless (PKCE) login:** tokens remember how they were obtained, so they refresh correctly.
- **Startup fixed:** the `tidal-dl-ng` and `tidal-dl-ng-gui` commands no longer fail to start with `No module named 'config'` when installed with pip.
- **Faster playlists:** large playlist libraries load in parallel, about 5× faster, with identical results.
- **FFmpeg fallback:** if the configured FFmpeg path doesn't exist, the usual install locations are tried.
- **No fake updates:** a failed update check no longer reports a bogus `v0.0.0` update.

## Credits

- **Engine:** [tidal-dl-ng](https://pypi.org/project/tidal-dl-ng/) by Robert Honz ([exislow](https://github.com/exislow)) and its contributors. The full commit history is preserved in this repository. The original repository (`github.com/exislow/tidal-dl-ng`) is no longer available.
- **TIDAL API:** [python-tidal](https://github.com/EbbLabs/python-tidal) (`tidalapi`).
- **macOS app and the changes listed above:** [23mystiq](https://github.com/23mystiq).

## License

[GNU AGPL-3.0](LICENSE), the same license as tidal-dl-ng. You can use, change and share this project, but versions you distribute must stay open source under the same license.

This project is not affiliated with TIDAL. Use it only for music you're entitled to download under your TIDAL subscription and local law.

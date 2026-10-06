# macOS app (Swift package)

The source of **TIDAL Downloader.app**. For features, requirements and install steps, see the [main README](../README.md).

```sh
macos/build.sh             # builds macos/build/TIDAL Downloader.app
macos/build.sh --install   # also copies it to /Applications
CONFIG=debug macos/build.sh
```

The app starts `python -m tidal_dl_ng.bridge` from the repository's `.venv` (the path is written into `Info.plist` at build time) and exchanges newline-delimited JSON with it.

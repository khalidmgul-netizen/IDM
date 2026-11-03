# Fetchly — a multi-connection download manager for macOS (Tahoe / 14+)

Native SwiftUI app with an IDM-style layout: category sidebar, toolbar (Add URL / Resume / Stop / Stop All / Delete / Options),
sortable download table (name, size, status, time left, rate, last try), per-download connection bars, menu-bar item,
scheduler, clipboard link detection and a Chrome extension that captures browser downloads.
Original code and name — not affiliated with, or derived from, any other product.

## Build (on a Mac with Xcode 15+ / Swift 5.9+)

    cd Fetchly
    swift test                      # engine unit tests
    ./scripts/make_app.sh           # -> build/Fetchly.app (ad-hoc signed)
    open build/Fetchly.app

Or open `Package.swift` in Xcode and run the `Fetchly` scheme. Building with the macOS 26 SDK picks up the Liquid Glass styling automatically.

> This project was written without access to a Swift compiler, so expect to fix a few small compile errors on first build.

## Test the engine without the GUI

    python3 scripts/range_server.py 8000 ~/Downloads --slow   # local server with HTTP Range support
    swift run fetchcli http://127.0.0.1:8000/somebigfile.zip /tmp 8

## Browser capture

1. Run the app, open Settings → Browser, click Copy next to the token.
2. Chrome: `chrome://extensions` → Developer mode → Load unpacked → pick the `Extension` folder.
3. Extension options → paste the token. Downloads started in Chrome now go to Fetchly (if the app is not running, Chrome downloads normally).
   Right-click a link → "Download with Fetchly" also works. Safari/Firefox need a small port of the extension.

## How it works

| Feature | Implementation |
|---|---|
| Faster downloads | up to 32 parallel `Range` requests, each writing at its own offset of a sparse `.part` file |
| Resume | per-connection progress is persisted to `~/Library/Application Support/Fetchly/downloads.json` |
| Queue | max simultaneous downloads (Settings), oldest first |
| Speed limit | per-task windowed throttle (global limit split across active downloads) |
| Retries | each connection retries 5× with backoff |
| Scheduler | start / stop unfinished downloads at set times while the app is running |

## Not built yet

Video/HLS grabber, site grabber, FTP, proxy and login credentials UI, Safari/Firefox extensions, app icon, notarization.

## Build online (no Xcode needed)

1. Create a GitHub repo and upload this folder (keep `.github/workflows/build.yml`).
2. Open the repo's Actions tab → "Build Fetchly" → Run workflow (it also runs on every push).
3. When it finishes, download the `Fetchly-macOS` artifact, unzip it, then run once in Terminal:
   `xattr -cr Fetchly.app` (the app is ad-hoc signed, not notarized) and open it.
If the build fails, the log shows the compile errors; paste them to Claude to get fixes.

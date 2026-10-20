# XGlyph

Mouse Battery Notifications and Indicator for macOS 13+.

- Low battery at 20% or less, full battery at 100%, and charging started alerts.
- Charging stopped alerts include the remaining charge; unplugging at 100% stays quiet.
- Optional menu-bar indicator, off by default, and launch at login.
- English, Russian, German, Spanish and Simplified Chinese, selected by macOS.

Tested with **DELUX M900 Pro over its 2.4 GHz receiver**. Other models are not
confirmed. Wired mode shows connection status; battery alerts require receiver
reports. XGlyph does not change mouse settings.

## Build and run

Requires Xcode Command Line Tools and Python 3 for tests. No third-party packages.

```sh
make
make test
```

Copy `build/XGlyph.app` to `~/Applications`, open it and allow notifications.
Enable **Launch at login** to start automatically. Closing the window keeps XGlyph
running; reopen the app to return to settings. **Send Test** checks notifications.
Focus and screen-sharing settings may silence notification sounds.

Change the app language in macOS **Language & Region**, then relaunch XGlyph.
Unsupported languages fall back to English. `make test-layout` checks translated
layouts and renders previews in `build/localized-previews/`. `make clean` removes
build outputs.
Local builds target the current Mac's architecture. For a universal build, run
`make clean` followed by `make ARCHS="arm64 x86_64" test`.
Builds are ad-hoc signed, not notarized.

## GitHub builds

GitHub Actions builds and tests the app on pushes, pull requests and manual runs.
Download **XGlyph-universal** from the run's **Artifacts** section: it contains a
ZIP for Apple Silicon and Intel, plus its SHA-256 checksum. No signing secrets
are required; the workflow does not publish releases.

## License

[MIT](LICENSE) · Copyright © 2026 GNineteen

Contact: me+xglyph@gnineteen.com

Uses Apple system frameworks. Protocol research consulted
[LinShark](https://github.com/JSjuan/LinShark); no code from that project or vendor
firmware is included.

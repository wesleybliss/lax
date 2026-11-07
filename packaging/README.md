# Packaging

Release packages are built from a binary you already built (`zig build -Doptimize=ReleaseSafe`). One script per OS family, one workflow (`.github/workflows/release.yml`) that runs them on native runners when you push a `vX.Y.Z` tag.

| OS | Formats | How |
| --- | --- | --- |
| Linux (x86_64, aarch64) | zip, deb, rpm, AppImage, Flatpak | `packaging/package.sh zip deb rpm appimage flatpak` |
| macOS (universal) | .app, dmg, zip | `packaging/package.sh app dmg zip` on a Mac |
| Windows (x86_64) | zip, MSI | `packaging\windows\package.ps1` |

Output goes to `dist/`. Tools: [nfpm](https://nfpm.goreleaser.com) (deb, rpm), `appimagetool` (downloaded on demand), `flatpak-builder`, WiX v4 (`dotnet tool install --global wix`), and the macOS tools (`hdiutil`, `iconutil`, `codesign`, `notarytool`).

Build Linux binaries for glibc 2.31 so they run on older distros: `zig build -Dtarget=x86_64-linux-gnu.2.31 -Doptimize=ReleaseSafe`.

## Cutting a release

1. Push a tag: `git tag v0.1.0 && git push origin v0.1.0`
2. The workflow tests, builds, packages and publishes a GitHub release with `SHA256SUMS`.

macOS signing and notarizing use these repo secrets, and are skipped (ad-hoc signed app) without them: `MACOS_CERTIFICATE` (base64 Developer ID .p12), `MACOS_CERTIFICATE_PASSWORD`, `MACOS_SIGN_IDENTITY`, `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`.

## Layout

- `icon/`: `lax.svg` is the source; the PNGs and `lax.ico` are rendered from it (`rsvg-convert`, `magick`).
- `linux/`: desktop entry, AppStream metainfo, `nfpm.yaml`, Flatpak manifest. App id: `dev.lax.Lax`.
- `macos/`: `Info.plist`, entitlements.
- `windows/`: `lax.wxs`, `package.ps1`.

## Status

- Verified here: Linux zip, deb, rpm, AppImage (built, contents checked, not launched).
- Not verified (no machine for it): Flatpak, everything macOS, everything Windows.
- Windows does not compile yet: the websocket dependency calls `Io.VTable.netRead`, which Zig 0.17 lacks. The Windows job is `continue-on-error` until that is ported.
- Credentials: Lax reads the Slack desktop session and keeps its own in the Secret Service through `secret-tool`, which is Linux only. On macOS and Windows you would paste a token each launch until a native keychain backend exists.

# Packaging

Release packages are built from a binary you already built (`zig build -Doptimize=ReleaseSafe`). One script per OS family, GitHub Actions workflows that run them on native runners.

| OS | Formats | How |
| --- | --- | --- |
| Linux (x86_64, aarch64) | zip, deb, rpm, AppImage, Flatpak | `packaging/package.sh zip deb rpm appimage flatpak` |
| macOS (universal) | .app, dmg, zip | `packaging/package.sh app dmg zip` on a Mac |
| Windows (x86_64) | zip, MSI | `packaging\windows\package.ps1` |

Output goes to `dist/`. Tools: [nfpm](https://nfpm.goreleaser.com) (deb, rpm), `appimagetool` (downloaded on demand), `flatpak-builder`, WiX v4 (`dotnet tool install --global wix`), and the macOS tools (`hdiutil`, `iconutil`, `codesign`, `notarytool`).

Build Linux binaries for glibc 2.31 so they run on older distros: `zig build -Dtarget=x86_64-linux-gnu.2.31 -Doptimize=ReleaseSafe`.

## Workflows

- `ci.yml`: tests and a Linux release build on every push to `master` and every pull request.
- `release.yml`: builds the Linux packages (x86_64 and aarch64) and publishes a GitHub release with `SHA256SUMS`. Run it by tagging, or from the Actions tab:
    1. `git tag v0.1.0 && git push origin v0.1.0`, or Actions > release > Run workflow (leave the version empty for the next patch; it creates the tag).
- `extra-platforms.yml`: macOS and Windows packages, by hand, artifacts only. Not part of the release until those are ready.

macOS signing and notarizing use these repo secrets, and are skipped (ad-hoc signed app) without them: `MACOS_CERTIFICATE` (base64 Developer ID .p12), `MACOS_CERTIFICATE_PASSWORD`, `MACOS_SIGN_IDENTITY`, `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`.

## Self-update (Linux)

On startup and every 30 minutes Lax asks GitHub for the latest release. When it is newer, an arrow appears above the account button; clicking it downloads the matching file, checks it against `SHA256SUMS`, and installs it:

- rpm / deb: `pkexec dnf install` / `pkexec apt-get install` (polkit shows the password prompt), then Lax restarts.
- AppImage: the running `.AppImage` is replaced in place (its folder must be writable), then Lax restarts.
- zip, `zig build` and Flatpak installs never check. `LAX_NO_UPDATE=1` turns it off.

Release assets must keep their arch in the name (`x86_64`, `aarch64`, `amd64`, `arm64`) and each release needs `SHA256SUMS`: the updater picks files by extension and arch. Code: `src/app/updater.zig`.

## Layout

- `icon/`: `lax-1024.png` is the source (transparent background); the other PNGs and `lax.ico` are resized from it with `magick`.
- `linux/`: desktop entry, AppStream metainfo, `nfpm.yaml`, Flatpak manifest. App id: `com.gammagamma.lax`. Licensed PolyForm Noncommercial 1.0.0 (`/LICENSE`), shipped in every package.
- `macos/`: `Info.plist`, entitlements.
- `windows/`: `lax.wxs`, `package.ps1`.

## Status

- Verified here: Linux zip, deb, rpm, AppImage (built, contents checked, not launched). The workflows themselves have never run on GitHub.
- Not verified (no machine for it): Flatpak, everything macOS, everything Windows.
- Windows does not compile yet: the websocket dependency calls `Io.VTable.netRead`, which Zig 0.17 lacks. The Windows job is `continue-on-error` until that is ported.
- Credentials: Lax reads the Slack desktop session and keeps its own in the Secret Service through `secret-tool`, which is Linux only. On macOS and Windows you would paste a token each launch until a native keychain backend exists.

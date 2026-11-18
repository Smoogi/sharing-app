# Smoogi Share

Private "message yourself" inbox that syncs directly between your own devices over the local network. No server, account, cloud, telemetry or internet needed.

**Status: Milestones 1-3 implemented and covered by automated tests (loopback). Not yet exercised on physical devices — see "Verification status".**

## Architecture

```
lib/
  core/        identity (Ed25519), protocol/message model, byte+crypto helpers, LAN address discovery
  transport/   peer_channel.dart  = Transport / PeerChannel interfaces (the ONLY thing sync sees)
               secure_tcp_transport.dart = LAN TCP implementation + secure handshake
  data/        SQLite: app_database, message_repository (append-only), peer_repository
  services/    connection_manager (reconnect, pairing flow, sync protocol), pairing_service (QR token)
  app/         AppController (ChangeNotifier glue for the UI)
  ui/          home_screen (inbox), devices_screen (pairing / paired devices)
```

A future internet relay = another `Transport`/`PeerChannel` implementation; DB, sync and UI are untouched.

### Security design (no custom primitives)
- Identity: Ed25519 key pair per device; device id = first 16 bytes of SHA-256(public key).
- Handshake: X25519 ephemeral keys with commit/reveal (initiator commits to `SHA-256(ephPub)` first, which blocks key grinding to force equal SAS codes), HKDF-SHA256 session keys per direction, ChaCha20-Poly1305 with counter nonces for every frame. Each side then signs `label || role || transcript` with its Ed25519 key (STS/SIGMA pattern), so identity is bound to that exact key exchange.
- Trust is separate from transport:
  - **Paired device** → public key is pinned in SQLite; a connection proving a different key is refused.
  - **Manual pairing** → both screens show a 6-digit code derived from the handshake transcript; user approves on BOTH devices. A man-in-the-middle ends up with different codes.
  - **QR pairing** → QR holds the host's public key (scanner pins it) plus a one-time 32-byte token; the scanner proves it with `HMAC(token, transcript)`. Token expires in 5 minutes and is single use. The host still has to tap Approve.
  - Unknown devices are refused outright unless the Devices screen is open on the receiving device. A LAN connection alone gives no access to messages.
- The composition is built from standard primitives (`cryptography` package) but has **not been independently audited**.

### Sync model
Append-only. Every message has a UUID and `(originDevice, originSeq)` with `originSeq` contiguous per origin. A device's "vector" = `{origin: highest seq held}`. On connect both sides exchange vectors and send what the other lacks; a message is accepted only if it is exactly `max+1` for its origin, so histories can never have holes or duplicates, and independently created offline messages merge cleanly. Messages relay through third devices (A↔B↔C converge without A and C being paired). Peers report their vectors back, which drives the Synced / Pending n/m label. The "offline queue" is the database itself, so nothing is lost on restart.

### Files
A shared file is a message of kind `file` whose body is `{name,size,sha256,mime}`; that metadata syncs like text. Bytes move only when you tap **Download** (streamed in 48 KB chunks over the encrypted channel, written to `<name>.part`, SHA-256 verified, then renamed). Interrupted transfers keep the `.part` and resume from its length. The origin device is tried first, then any other connected device that already holds the file; if none is online the UI says so instead of failing silently. Each file lives in `attachments/<messageId>/<name>`, so nothing is ever overwritten; "Save to Downloads" (desktop) adds ` (1)` suffixes.

### Android Share menu
`MainActivity.kt` accepts `ACTION_SEND` / `ACTION_SEND_MULTIPLE` (text, URLs, images, any file). Content URIs are streamed into the app cache immediately (so they stay valid), then imported into app storage and queued for sync. No storage permissions are used. Camera permission is only for scanning the pairing QR.

### Discovery
UDP broadcast beacons on port 48621 (`{id, port}` every 5 s). A paired device that changed IP is rediscovered and reconnected automatically; beacons are only hints and the TCP connection is still pinned to the paired key. (Used instead of mDNS to avoid extra packages and Android multicast-lock issues. mDNS could be added behind the same `onDiscovered` hook.)

### Imageboard-style posts, replies and threads
Every message gets a stable 9-digit post number (`No.123456789`, derived from its UUID, so identical on all devices). A reply is just text containing `>>123456789`: it syncs, edits and searches like any text and needs no protocol change (older builds show it as plain text). The UI is styled after Yotsuba (light) / a dark board variant: header bar with name, date and No., tap the No. to reply, `>greentext` lines, red `>>` quote links that jump to the post (marked "(You)" for your own posts), backlink rows under each post, `#` to open the thread (everything connected by quotes), and search by text, device name or post number.

### Editing messages
Still append-only: an edit is a new message of kind `edit` (`{t: targetId, b: newText}`) that syncs like any other. Every device shows the newest edit (by time, then device id) with an "edited" label; the original row is never rewritten. Any paired device can edit any text message. Files cannot be edited.

### Auto-download
Devices screen -> "Auto-download files up to" (Off / 5 / 10 / 25 / 100 MB, default 10). Larger files stay "not downloaded" until you tap Download.

### Identity key storage
Android: AES-GCM key in the Android Keystore wraps the seed. Windows: DPAPI (bound to your Windows account). Linux/macOS: still an app-private file (TODO libsecret/Keychain). An old file-based seed is migrated automatically after a verified round trip. If a vaulted key goes missing the app refuses to start rather than silently creating a new identity.

### Protocol version
Protocol v2 (binary file chunks). v1 builds refuse to sync with v2 and say so; update all devices together.

## Run

Requirements: Flutter 3.47+, Android SDK, and for Windows/Linux/macOS plugin builds on Windows **Developer Mode ON** (`start ms-settings:developers`, needed for symlinks).

```powershell
flutter pub get
flutter test                                  # 52 automated tests
flutter run -d <device-id>
flutter build apk --release --target-platform android-arm64   # arm64 only
flutter build windows                          # needs Developer Mode
powershell -File installer\build_installer.ps1  # dist\smoogi-share-setup.exe (IExpress, per-user, no admin)
```

## Manual test procedure (Android <-> Android) - NOT yet performed by the author
1. Same Wi-Fi (no client isolation). Install the arm64 APK on both phones.
2. Phone A: Devices screen (keep it open). Phone B: Devices -> **Scan other device** (or enter A's IP:port and compare the 6-digit codes, approving on both).
3. Send text each way; status goes Pending -> Synced.
4. Share from another app (e.g. a log, a photo from Gallery) via the Share menu -> choose Smoogi Share. It appears in the inbox.
5. On the other phone, tap **Download**; open the file. Turn Wi-Fi off mid-download: status becomes "interrupted"; reconnect and tap **Resume**.
6. Close one app, create messages on both, reopen: histories merge. Toggle airplane mode / change Wi-Fi: the phones find each other again within ~10 s.

Android <-> Windows: run the Windows build, open Devices on Windows, pair the phone by scanning the Windows QR (or pasting its pairing code / entering IP:port). Allow the Windows Firewall prompt (private networks). Drag a file onto the window to share it.

## Verification status (honest)
- Automated, passing: serialization, duplicate/gap/conflict handling, sync reconciliation, offline queue persistence, pairing authentication (SAS, QR token, pinned key, tamper detection), discovery beacons, file integrity, interrupted/resumed transfers, unavailable sources, relay serving, filename safety.
- Built successfully: Android release APKs.
- **Not verified:** the UI on any real device, Share-menu import, QR scanning, Android<->Android and Android<->Windows transfers, Windows/Linux/macOS builds. Windows build could not be run here because Developer Mode is off (it is a system setting I may not change). Linux and macOS were never built (need those OSes); macOS entitlements for networking/camera/downloads are added.

## Known limitations
- Handshake is composed from standard primitives but has not been independently audited.
- Identity seed is in the OS keystore on Android/Windows only (see above).
- Transfers use pure-Dart ChaCha20-Poly1305 over binary frames: about 8-10 MB/s measured on loopback in a debug VM (release is faster); fine for typical files, slow for multi-GB.
- Android may close sockets when backgrounded (no background service in V1); reconnect occurs on resume.
- Broadcast discovery assumes /24 subnets plus 255.255.255.255; some routers block broadcasts between Wi-Fi and wired segments - use manual address then.
- Message order uses origin clocks; per-origin order is always exact.
- Text messages max 1 MiB; use a file for larger content.
- `desktop_drop` is pinned below 0.9 and `file_selector` is used instead of `file_picker` because of a `cross_file` version conflict.
- Deletion and background sync are out of scope for V1.

## Desktop CI
`.github/workflows/build.yml` builds and tests Linux and builds macOS (unsigned) on GitHub's runners (manual run, or on `v*` tags where it also attaches the artifacts to the release). macOS builds are unsigned: right-click -> Open the first time.

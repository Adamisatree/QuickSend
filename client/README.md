# QuickSend Native (v1.1 development)

The Flutter client replaces the old web-rendered interface with a Material 3 native UI. This is an in-progress v1.1 implementation; it has **not** been signed, released, or validated as production-ready on every target architecture.

## Implemented in this branch

- Native Flutter dashboard for file selection, device selection, chat, incoming approvals, and transfer progress.
- A temporary, in-process LAN WebSocket relay. One device starts it; others enter its IP and port. Devices must use the same private room key.
- Ephemeral X25519 keys authenticated by an HMAC derived from the room key; per-transfer keys are delivered in X25519/HKDF/ChaCha20-Poly1305 envelopes. File names and SHA-256 manifest are inside the encrypted envelope. Chunk payloads use fresh nonces and are authenticated before writing.
- Receiver approval/rejection, 256 KiB encrypted chunks, an eight-chunk acknowledgement window for backpressure, and final SHA-256 verification. Transfer is lossless or fails closed; there is no lossy media compression.
- Recursive folder selection (files and relative paths), encrypted group-chat messages, online peer listing with IPs, group invitations, and in-memory group history.
- Received files are placed under the app documents directory at `QuickSend/Received/<transfer-id>` and can be shared from the transfer screen.

## Run locally

Install a current stable Flutter SDK, then:

```sh
cd client
./tool/bootstrap_platforms.sh
flutter pub get
flutter analyze
flutter test
flutter run -d <device>
```

The bootstrap script generates Flutter's native runner projects. It does not sign or provision iOS. Android and iOS require their normal SDKs; iOS release distribution requires an Apple Developer team and signing profiles.

## Security notes

- Choose a **long, random room key** and deliver it out-of-band. A weak room key can be guessed offline because the room identifier is a SHA-256 digest. The app enforces 12 characters but that is only a minimum, not a recommendation.
- The relay is plain `ws://` on the LAN and can observe peer names/IPs, transfer sizes/timing, group metadata, and chat sender/time metadata. Chat text, filenames, folder paths, file digests, and file contents are encrypted end-to-end. The relay can deny service or withhold data; it cannot make tampered chunks pass authentication/integrity checks.
- This implementation is a new protocol and has **not** received an independent security review. Do not use it for regulated or high-risk data yet. No persistent identity, certificate pinning, key recovery, or safe resume after app restart is implemented. A source-level hardening pass now validates transfer UUIDs and cross-platform paths, caps relay control-message/peer/group/transfer resources, verifies file digests, and rejects chunks exceeding the declared file size; these checks do not replace a cryptographic protocol audit.
- Sharing a room key gives room members the ability to authenticate as a member; do not use a shared room with untrusted participants.

## Platform and background status

The Flutter project can generate runners for Windows, macOS, Linux, Android, and iOS. CI release builds have passed on native runners for Windows x64/ARM64, macOS Intel/Apple Silicon, Linux x64/ARM64, Android APK, and unsigned iOS. This is compile-time validation only: clean-machine installation and physical-device transfer testing remain open. macOS signing/notarization, iOS provisioning, and production Android signing are not configured.

The relay runs while the process is alive. Desktop minimize keeps the process alive, but there is no system-tray service yet. Android foreground-service integration and iOS background transfer support are not implemented. Mobile operating systems can suspend/terminate a background app; iOS especially does not guarantee continuous arbitrary LAN socket work. Treat mobile transfers as foreground-only in this development build.

## Limits in this prototype

One transfer is limited to 100 files and 500 GiB total; individual files are capped at 100 GiB. The server buffers no file payload to disk but keeps group history in memory. Folder empty directories, persistent chat history, automatic device discovery, retries after reconnect, partial resume, and internet relay traversal are not implemented. Internet access requires users to configure routing/firewalls themselves and is not recommended with this unauthenticated plain-WebSocket relay.

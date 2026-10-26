# QuickSend v1.1 protocol review (internal source review)

**Status: preliminary hardening review; not an independent audit or release approval.** Reviewed the Flutter client and in-process LAN relay on 2026-10-26. Regression coverage was run in CI, but no physical-device, hostile-network, fuzz, penetration, or third-party cryptographic review was performed.

## Findings addressed in this branch

| Severity | Finding | Mitigation |
|---|---|---|
| High | An untrusted transfer identifier was used as a received-files directory component. | Accept only UUID v4 IDs before creating a destination. Existing destinations are rejected; new output files are created exclusively. |
| High | The receiver could append authenticated chunks beyond the declared file size until final verification, consuming disk. | Enforce per-chunk and cumulative per-file limits at the receiver; the relay also counts and bounds each file's forwarded bytes and requires an exact byte total before completion. |
| High | File paths were normalized by removing unsafe segments, which could cause traversal or silent name collisions across OSes. | Validate rather than rewrite paths; reject absolute paths, traversal, control characters, Windows device names, non-portable segments, and case-insensitive collisions. |
| Medium | Relay sessions, control traffic, pending transfers, and unacknowledged chunks had no aggregate bounds. | Limit sessions, JSON size, per-session control-message rate, groups, active transfers, and in-flight chunks; expire incomplete handshakes. These are abuse limits, not a guarantee against a hostile LAN peer. |
| Medium | A peer closing during relay fan-out could throw from `WebSocket.add` into an unhandled asynchronous callback. | Catch send failures and close the stale socket quietly; add a two-peer relay regression test. |
| Medium | Interrupted or failed receives could leave partial files behind. | Remove partial transfer directories on cancellation, disconnect, or failed integrity verification. |

Tests cover transfer-ID and path policy, malformed auth-tag encoding, rejected invalid transfer IDs, and a relay attempt to exceed a declared one-byte file. The complete Flutter matrix and Node suite passed in [Flutter run 40267805610](https://github.com/Adamisatree/QuickSend/actions/runs/40267805610) and [Node run 40267805113](https://github.com/Adamisatree/QuickSend/actions/runs/40267805113).

## Open risks and release blockers

1. **Room-key guessing:** the room identifier is an unsalted SHA-256 of the shared room key, and peer authentication is an HMAC derived from that key. Captured traffic permits offline guesses. The UI can generate a 32-character random key, but the 12-character manual-input minimum does not provide an entropy guarantee. There is no PAKE or memory-hard password KDF.
2. **Transport metadata:** the relay uses plain `ws://`. LAN observers can see IP addresses, names, group metadata, file sizes, timing, and chat sender/timestamp metadata. End-to-end encryption protects file contents, paths, digests, and chat text, but does not hide that traffic pattern.
3. **Relay trust/availability:** the relay is unauthenticated and can deny service, drop/reorder application messages, or expose metadata. Clients verify peer HMACs before transfer, but server-side auth is only format-checked because the relay does not know the room secret.
4. **Resource exhaustion:** authenticated room participants can request transfers up to the prototype's 500 GiB limit. There is no reliable cross-platform free-space reservation, per-user quota, durable queue, or administrator policy. Recipients must approve each transfer and should not accept untrusted peers.
5. **Local filesystem race:** lexical path validation and exclusive creation reduce traversal and overwrite risk, but this implementation does not use platform-specific directory handles/openat-style APIs to make every nested path operation race-free against a hostile local process.
6. **Lifecycle:** transfers do not resume after reconnect or process termination. Android foreground-service behavior, iOS background transfers, and desktop tray operation are not implemented. Do not assume transfers continue when the OS suspends the app.
7. **Identity and code signing:** peer identities are ephemeral per connection, with no persistent device identity, revocation, certificate pinning, key rotation, or managed trust store. Android production signing and Apple signing/notarization are not configured.

Before a stable release, an independent reviewer should assess the key schedule, room membership/authentication model, nonce/replay guarantees, protocol state transitions, filesystem behavior on each OS, and resource limits. Real-device transfer and install tests, plus properly provisioned signing identities, are still required.

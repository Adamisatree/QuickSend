# Release signing prerequisites

Signing identities are intentionally not generated, embedded, or committed by this repository. They identify the publisher, require account/organization ownership, and their private keys must remain under that owner's control. Do not send certificates, keystores, passwords, recovery codes, or private keys in chat or commit them to Git.

## Windows

Obtain an Authenticode code-signing certificate for the publisher identity and use a protected signing service or CI secret-backed PFX. Sign the app executable and every packaged native binary; timestamp the signatures. Verify each x64 and ARM64 artifact with `signtool verify /pa /all /v` on a clean Windows machine. Certificate acquisition requires the publisher's legal identity and CA/account validation.

## macOS

Use the publisher's Apple Developer account to issue a **Developer ID Application** identity for distribution outside the Mac App Store. Sign the `.app` and embedded code, create the DMG, notarize it with Apple's notary service, staple the ticket, and verify with `codesign --verify --deep --strict` and `spctl --assess`. Keep App Store Connect API credentials in repository/environment secrets if used; prefer API-key auth over an individual's Apple ID password.

## iOS

An iOS App Store or ad-hoc IPA requires the publisher's Apple Distribution identity, matching provisioning profile, registered bundle identifier, and an Apple Developer team. Validate installation on actual supported devices and use TestFlight/App Store Connect for distribution. An unsigned `flutter build ios --no-codesign` output is not an installable release IPA.

## Android

Create an organization-owned upload keystore, back it up offline under the publisher's key-management policy, and use Play App Signing for store distribution where applicable. Store the keystore and passwords in protected CI secrets, never in source control. A debug-signed APK is only a test artifact and is not the production signing identity.

## This repository's current state

The current Flutter workflow builds validation artifacts only. No Windows, Apple, or production Android signing identity or credentials are configured; there is no v1.1 publishing workflow. Setting up GitHub Actions secret names alone does not create or validate these certificates. The publisher must obtain the identities, configure the repository's protected secrets/environments, and run the signed release workflow on their own account. Signature verification and clean-machine install checks remain mandatory.

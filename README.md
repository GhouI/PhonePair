# PhonePair

A small iOS 27+ app that creates a **remote pairing file on your iPhone**, ready
to export and import into StikDebug. Approve pairing in Developer Mode settings;
no computer or existing pairing file is required for the pairing exchange.

The first prototype was tested by its owner: on-device pairing, verification
through LocalDevVPN, and using the exported file with StikDebug for JIT all
worked. This is one user-reported iOS 27 test, not a broad compatibility guarantee.
See [TESTING.md](TESTING.md) for the checks and remaining limitations.

## Download

Get the IPA from [Releases](https://github.com/GhouI/PhonePair/releases).
Sign and install it with your preferred sideloading service. The download is not
provisioned for direct installation on a stock iPhone.

## Test on the iPhone

1. Sign `PhonePair-0.1.0.ipa` using your existing signing service, then install it.
2. Join Wi-Fi. Open PhonePair and tap **Start on-device pairing**. Allow Local
   Network and Notifications. No special multicast entitlement is requested.
3. Open **Settings → Privacy & Security → Developer Mode**. Look for **Pair with
   PhonePair on this iPhone** and select it. Read the six-digit code from the
   PhonePair notification, or switch back to PhonePair to read it, and enter the
   code in Settings. The code appears after selecting the host in Settings,
   when the pairing handshake starts; tapping Start alone does not issue a code.
4. Return promptly. Background time is limited. If time expires, restart the
   pairing attempt. This version uses a normal finite background task, without
   audio playback or an embedded VPN extension.
5. After the pairing exchange completes, connect **LocalDevVPN**, return to
   PhonePair and tap **Verify with LocalDevVPN**.
6. If verification succeeds, tap **Export pairing file**, save it in Files, then
   import it into StikDebug and try enabling JIT. This app does not change
   StikDebug's existing file automatically.

Verification checks the remote pairing identity at `10.7.0.1:49152`; it does not
claim that a developer disk image is mounted or that JIT was enabled. Wireless
pairing persistence after restarting the phone must be tested separately.

If the host never appears in Settings, share the app's diagnostics and report
the exact iOS version. A publication success message means Bonjour accepted
the advertisement, not that Settings discovered it. Do not delete your working
StikDebug pairing while testing.

## Data

Generated keys live in the app's private Application Support directory, with
file protection and backup exclusion. Only a completed exchange writes a pairing
record. Diagnostics record stages and error messages without keys or PINs.
Export is a deliberate action using the iOS share sheet. No analytics, remote
backend, signing account access, or third-party upload is included.

## Build on Linux

Requirements: Rust with the `aarch64-apple-ios` target, Clang, `ld64.lld`, Python 3,
and an iOS SDK. The initial build used the iOS 16.5 SDK with an iOS 27 runtime
requirement. An SDK and signing credentials are not included in this repository.

```sh
rustup target add aarch64-apple-ios
cargo test --manifest-path core/Cargo.toml --locked
PHONEPAIR_IOS_SDK=/path/to/iPhoneOS16.5.sdk bash scripts/build-linux.sh
```

Override `PHONEPAIR_IOS_SDK` or `PHONEPAIR_CARGO` for other installations.
The resulting IPA is **ad-hoc signed for packaging**, and must be re-signed by
your signing service before installation on a stock iPhone. No signing
certificate or provisioning profile is included.

## Implementation and sources

The app uses UIKit and the open-source `idevice` Rust library pinned to
`26a28f6a46b5d85a28043c2e62febfa394c8b0a6`. Native `NSNetService` advertises the
service with the TXT records produced by `PairableHostInfo`. A dual-stack TCP
listener runs the library's SRP/Ed25519 remote pairing responder. A local
notification shows the PIN while Settings is in front. The app serializes
`RpPairingFile` only after the responder completes and supplies a peer identity.

- Protocol and responder: https://github.com/jkcoxson/idevice
- Desktop reference: https://github.com/jkcoxson/idevice_pair
- Existing iOS self-pairing example examined during research:
  https://github.com/Mak5er/AirCard-iOS
- StikPair is an existing dedicated app using the same pairing method:
  https://github.com/StikDebug/StikPair
- Apple's local network privacy guidance:
  https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy

The upstream idevice repository has an AI contribution policy requiring human
review and disclosure for contributions. This project is a separate prototype;
no upstream contribution or PR was made. New app and bridge code was generated
with AI assistance and should be reviewed before wider distribution.

This is an independent implementation of an existing technique, not a new
pairing protocol or an official StikDebug project.

## License

PhonePair's original code is available under the [MIT License](LICENSE).
Dependencies retain their own licenses; see [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt)
and [Dependency-Licenses.txt](Dependency-Licenses.txt).

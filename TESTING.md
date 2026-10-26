# Prototype validation — 26 October 2026

Completed on Linux:

- `cargo test --manifest-path core/Cargo.toml --locked` passed. The lifecycle test
  checks malformed protocol input, a real SRP exchange with an incorrect PIN,
  cancellation, restarting with a fresh identity, rejection of overlapping
  operations, private file permissions, and preservation of a previous record.
  Failed and cancelled exchanges did not create a new pairing file.
- `cargo fmt --manifest-path core/Cargo.toml --check` passed.
- The Rust core compiled for `aarch64-apple-ios` in release mode.
- UIKit Objective-C compiled with Clang's warnings enabled and no diagnostics.
- `ld64.lld` linked an arm64 Mach-O executable with no unresolved symbols. Its
  load commands reference only system libraries/frameworks.
- The IPA archive passed ZIP integrity and bundle metadata checks. It contains
  no existing pairing file, private signing certificate, or provisioning profile.

## Owner-reported device test

On 26 October 2026, the owner reported that signing/installing the IPA and the
full flow worked on their iPhone running iOS 27: Settings discovered PhonePair,
the pairing exchange completed, Verify passed through LocalDevVPN, and the
exported file worked with StikDebug for JIT. No existing pairing record was
bundled in the IPA. This was a user-reported result, not an automated device test.

The exact iOS patch version and iPhone model were not recorded. Other devices,
other iOS versions, persistence after reboot, and long background sessions have
not been validated. The app remains an experimental release.

Runtime diagnostics appear in the app and can be shared without pairing keys
or the six-digit pairing PIN.

#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
sdk_dir="${PHONEPAIR_IOS_SDK:-}"
cargo_bin="${PHONEPAIR_CARGO:-$HOME/.cargo/bin/cargo}"
test -f "$sdk_dir/SDKSettings.plist" || { echo "Set PHONEPAIR_IOS_SDK to an extracted iOS SDK." >&2; exit 1; }
"$cargo_bin" build --manifest-path core/Cargo.toml --release --target aarch64-apple-ios --locked
app_dir="$project_dir/build/Payload/PhonePair.app"
mkdir -p "$app_dir"
clang -target arm64-apple-ios17.4 -isysroot "$sdk_dir" -fobjc-arc -fblocks -O2 \
    -Wall -Wextra -Wno-unused-parameter -c ios/main.m -o build/main.o
ld64.lld -arch arm64 -platform_version ios 17.4 16.5 -syslibroot "$sdk_dir" \
    -o "$app_dir/PhonePair" build/main.o core/target/aarch64-apple-ios/release/libphonepair_core.a \
    -framework UIKit -framework Foundation -framework UserNotifications -framework Security \
    -framework CoreFoundation -framework CoreGraphics -lobjc -lSystem -liconv \
    -dead_strip -adhoc_codesign
cp ios/Info.plist "$app_dir/Info.plist"
cp THIRD_PARTY_NOTICES.txt "$app_dir/THIRD_PARTY_NOTICES.txt"
cp Dependency-Licenses.txt "$app_dir/Dependency-Licenses.txt"
python3 scripts/package.py

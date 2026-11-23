#!/usr/bin/env bash
# Build nurby-core (with the vendored SolidCraft kernel) for iOS device + simulator, generate the
# Swift bindings, and package ios/NurbyCore.xcframework + ios/Nurby/Generated/nurby_core.swift.
# Run on the Mac (needs Xcode). The toolchain and iOS targets come from rust-toolchain.toml.
set -euo pipefail
cd "$(dirname "$0")/.."

# No debug info in the static libraries: they are large enough as it is.
export CARGO_PROFILE_RELEASE_DEBUG=false
cargo build -p nurby-core --lib --release --target aarch64-apple-ios
cargo build -p nurby-core --lib --release --target aarch64-apple-ios-sim

SIM_LIB=target/aarch64-apple-ios-sim/release/libnurby_core.a
DEV_LIB=target/aarch64-apple-ios/release/libnurby_core.a

GEN=target/uniffi-swift
rm -rf "$GEN" && mkdir -p "$GEN"
cargo run -q -p uniffi-bindgen -- generate --library "$SIM_LIB" --language swift --out-dir "$GEN"

HDRS=target/uniffi-headers
rm -rf "$HDRS" && mkdir -p "$HDRS"
cp "$GEN"/*.h "$HDRS"/
cp "$GEN"/nurby_coreFFI.modulemap "$HDRS"/module.modulemap

rm -rf ios/NurbyCore.xcframework
xcodebuild -create-xcframework \
  -library "$DEV_LIB" -headers "$HDRS" \
  -library "$SIM_LIB" -headers "$HDRS" \
  -output ios/NurbyCore.xcframework

mkdir -p ios/Nurby/Generated
cp "$GEN"/nurby_core.swift ios/Nurby/Generated/
echo "Built ios/NurbyCore.xcframework and ios/Nurby/Generated/nurby_core.swift"

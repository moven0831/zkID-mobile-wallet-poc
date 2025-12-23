#!/bin/bash
set -e

# Pre-build GMP for iOS to avoid Xcode environment issues
# This script ensures GMP is built in a clean terminal environment
# before Xcode attempts to build the Rust crate

echo "=================================================="
echo "Pre-building GMP for iOS..."
echo "=================================================="

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ECDSA_DIR="$PROJECT_ROOT/wallet-unit-poc/ecdsa-spartan2"

cd "$ECDSA_DIR"

# Build for iOS arm64 (actual device)
echo "Building for aarch64-apple-ios (iOS device)..."
export IPHONEOS_DEPLOYMENT_TARGET=13.0
cargo build --target aarch64-apple-ios --release 2>&1 | grep -E "(Compiling ecdsa-spartan2|Finished)" || true

# Find the successful build directory
TERMINAL_BUILD=$(find "$ECDSA_DIR/target/aarch64-apple-ios/release/build" -name "ecdsa-spartan2-*" -type d | head -1)

if [ -z "$TERMINAL_BUILD" ]; then
    echo "ERROR: Could not find terminal build directory"
    exit 1
fi

echo "✓ GMP built successfully in terminal environment"
echo "Terminal build: $TERMINAL_BUILD"

# Find Xcode derived data build directories and copy pre-built GMP
echo ""
echo "Copying pre-built GMP to Xcode build directories..."

XCODE_BUILDS=$(find ~/Library/Developer/Xcode/DerivedData/Runner-*/Build/Intermediates.noindex/Pods.build/Release-iphoneos/mopro_flutter_bindings.build/aarch64-apple-ios/release/build/ -name "ecdsa-spartan2-*" -type d 2>/dev/null || true)

if [ -z "$XCODE_BUILDS" ]; then
    echo "ℹ No Xcode build directories found (this is normal before first build)"
else
    for XCODE_BUILD in $XCODE_BUILDS; do
        echo "  Copying to: $XCODE_BUILD"
        mkdir -p "$XCODE_BUILD/out/witnesscalc/depends/gmp/"

        if [ -d "$TERMINAL_BUILD/out/witnesscalc/depends/gmp/package_ios_arm64" ]; then
            cp -r "$TERMINAL_BUILD/out/witnesscalc/depends/gmp/package_ios_arm64" \
                  "$XCODE_BUILD/out/witnesscalc/depends/gmp/"
            echo "  ✓ Copied GMP to Xcode build"
        fi
    done
fi

echo ""
echo "=================================================="
echo "✓ Pre-build complete!"
echo "=================================================="
echo ""
echo "You can now run: flutter run --release"
echo "Or: flutter build ios --release"

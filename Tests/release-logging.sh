#!/bin/sh
set -eu

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

printf 'int main(void) { return 0; }\n' | clang -x c - -o "$work/clean"
printf '#import <Foundation/Foundation.h>\nint main(void) { NSLog(@"test"); return 0; }\n' |
    clang -x objective-c - -framework Foundation -o "$work/logging"

cat > "$work/build" <<'EOF'
#!/bin/sh
set -eu
mkdir -p "$TEST_RELEASE_DIR/BalanceKeeper.app/Contents/MacOS"
cp "$TEST_APP" "$TEST_RELEASE_DIR/BalanceKeeper.app/Contents/MacOS/BalanceKeeper"
cp "$TEST_AGENT" "$TEST_RELEASE_DIR/BalanceKeeper.app/Contents/MacOS/balancekeeperd"
EOF
chmod +x "$work/build"
export TEST_RELEASE_DIR="$work/release" TEST_APP="$work/clean" TEST_AGENT="$work/clean"

check_release() {
    make --no-print-directory release-app RELEASE_DIR="$TEST_RELEASE_DIR" RELEASE_IDENTITY=- \
        DIAGNOSTIC_LOG=0 MAKE="$work/build" > "$work/output" 2>&1
}

check_release
for binary in BalanceKeeper balancekeeperd; do
    TEST_APP="$work/clean"
    TEST_AGENT="$work/clean"
    if [ "$binary" = BalanceKeeper ]; then TEST_APP="$work/logging"; else TEST_AGENT="$work/logging"; fi
    if check_release; then
        echo "FAIL: release-app accepted logging symbols in $binary"
        exit 1
    fi
    grep -F "FAIL: logging symbols in $TEST_RELEASE_DIR/BalanceKeeper.app/Contents/MacOS/$binary" "$work/output"
done
echo "PASS: release-app checks both shipped binaries"

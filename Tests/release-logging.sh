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
cp "$TEST_UPDATER" "$TEST_RELEASE_DIR/BalanceKeeper.app/Contents/MacOS/balancekeeper-update"
EOF
chmod +x "$work/build"
export TEST_RELEASE_DIR="$work/release" TEST_APP="$work/clean" TEST_AGENT="$work/clean" TEST_UPDATER="$work/clean"

check_release() {
    make --no-print-directory release-app RELEASE_DIR="$TEST_RELEASE_DIR" RELEASE_IDENTITY=- \
        DIAGNOSTIC_LOG=0 MAKE="$work/build" > "$work/output" 2>&1
}

check_release
for binary in BalanceKeeper balancekeeperd balancekeeper-update; do
    TEST_APP="$work/clean"
    TEST_AGENT="$work/clean"
    TEST_UPDATER="$work/clean"
    case "$binary" in
        BalanceKeeper) TEST_APP="$work/logging" ;;
        balancekeeperd) TEST_AGENT="$work/logging" ;;
        balancekeeper-update) TEST_UPDATER="$work/logging" ;;
    esac
    if check_release; then
        echo "FAIL: release-app accepted logging symbols in $binary"
        exit 1
    fi
    grep -F "FAIL: logging symbols in $TEST_RELEASE_DIR/BalanceKeeper.app/Contents/MacOS/$binary" "$work/output"
done
echo "PASS: release-app checks all three shipped binaries"

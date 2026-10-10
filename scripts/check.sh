#!/bin/bash
# Checks Burn on this Mac before a push. It builds everything with warnings as errors, runs every
# test, and puts disc images, checksums and recovery data through macOS's own tools and par2. It
# also builds a fresh copy of the last commit, which catches a new file that was never committed.
#
# Usage: scripts/check.sh [--quick]
#   --quick   builds and tests only, for while you're working; run the full check before a push
#
# Needs Xcode, python3 and par2 (brew install par2). Everything it writes goes in scratch/check,
# which git ignores, and is removed once every check passes. It mounts its own test images there,
# read-only, while it runs. The full check takes about 5 minutes and needs about 10 GB free.

set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
WORK="$ROOT/scratch/check"

QUICK=false
for argument in "$@"; do
    case "$argument" in
        --quick) QUICK=true ;;
        -h|--help)
            sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown option: $argument (try --help)" >&2
            exit 2
            ;;
    esac
done

for tool in xcodebuild swift python3 par2; do
    if ! command -v "$tool" > /dev/null; then
        echo "$tool isn't installed. par2 comes from Homebrew: brew install par2" >&2
        exit 1
    fi
done

rm -rf "$WORK"
mkdir -p "$WORK/tmp"
# Tests and tools write their temporary files here, not in macOS's temporary folder.
export TMPDIR="$WORK/tmp"
MNT="$WORK/mnt"
mkdir -p "$MNT"
# Never leave a test image mounted, whatever fails.
trap 'hdiutil detach "$MNT" > /dev/null 2>&1 || true' EXIT

started=$(date +%s)
step() { printf '\n== %s\n' "$1"; }

# Shows the lines that matter from a log that failed, then stops.
failed() {
    grep -E "✘|error:|warning:|recorded an issue|Expectation failed|Fatal error|Precondition failed" "$2" \
        | sort -u | head -40 || true
    echo "$1 failed. Full log: $2" >&2
    exit 1
}

step "Build the package, with warnings as errors"
swift build --package-path Packages/BurnKit -Xswiftc -warnings-as-errors > "$WORK/build.log" 2>&1 \
    || failed "The package build" "$WORK/build.log"

step "Run every test"
swift test --package-path Packages/BurnKit -Xswiftc -warnings-as-errors > "$WORK/test.log" 2>&1 \
    || failed "The tests" "$WORK/test.log"
grep "Test run with" "$WORK/test.log"

step "Build the app"
# Its own build folder, kept between runs so later checks are quicker. scripts/run-app.sh uses another.
xcodebuild build -project Burn.xcodeproj -scheme Burn -destination 'platform=macOS' \
    -derivedDataPath "$ROOT/.build/check-xcode" > "$WORK/xcodebuild.log" 2>&1 \
    || failed "The app build" "$WORK/xcodebuild.log"
grep -E "(error|warning): " "$WORK/xcodebuild.log" | grep -v appintentsmetadataprocessor | sort -u || true

if $QUICK; then
    rm -rf "$WORK"
    echo
    echo "Quick check passed in $(( $(date +%s) - started )) s. Run scripts/check.sh before pushing."
    exit 0
fi

step "Build a fresh copy of the last commit"
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "Uncommitted changes aren't in the fresh copy, so commit before the check that comes before a push."
fi
git clone --quiet --no-hardlinks "$ROOT" "$WORK/fresh"
swift build --package-path "$WORK/fresh/Packages/BurnKit" -Xswiftc -warnings-as-errors \
    > "$WORK/fresh-build.log" 2>&1 || failed "The fresh copy's package build" "$WORK/fresh-build.log"
xcodebuild build -project "$WORK/fresh/Burn.xcodeproj" -scheme Burn -destination 'platform=macOS' \
    -derivedDataPath "$WORK/fresh-xcode" > "$WORK/fresh-xcodebuild.log" 2>&1 \
    || failed "The fresh copy's app build" "$WORK/fresh-xcodebuild.log"
rm -rf "$WORK/fresh" "$WORK/fresh-xcode"

swift build --package-path Packages/BurnKit --product burnctl > /dev/null
BURNCTL="$(swift build --package-path Packages/BurnKit --show-bin-path)/burnctl"
SRC="$WORK/src/Test Data"

step "A disc image through macOS"
mkdir -p "$SRC/sub dir/deeper/a/b"
printf 'hello\n' > "$SRC/hello.txt"
: > "$SRC/empty"
head -c 3000000 /dev/urandom > "$SRC/sub dir/random.bin"
printf 'accents\n' > "$SRC/sub dir/deeper/Café résumé.txt"
printf 'deep\n' > "$SRC/sub dir/deeper/a/b/deep.txt"
printf 'long\n' > "$SRC/$(printf 'L%.0s' $(seq 1 90)).txt"
"$BURNCTL" make-iso "$SRC" --output "$WORK/test.iso" --name "Round Trip"
hdiutil attach -readonly -nobrowse -mountpoint "$MNT" "$WORK/test.iso" > /dev/null
# A bridge image must mount as UDF, which macOS prefers when it can read it.
mount | grep "$MNT" | grep -q "(udf"
python3 scripts/compare-trees.py "$SRC" "$MNT"
# The checksum folder must check out with plain shasum, as it will years from now.
(cd "$MNT" && shasum -a 256 -c .burn/SHA256SUMS > /dev/null)
"$BURNCTL" verify-files "$MNT"
hdiutil detach "$MNT" > /dev/null

echo "Without UDF, the same files through ISO 9660 and Joliet:"
"$BURNCTL" make-iso "$SRC" --output "$WORK/plain.iso" --name "Plain" --no-udf
hdiutil attach -readonly -nobrowse -mountpoint "$MNT" "$WORK/plain.iso" > /dev/null
mount | grep "$MNT" | grep -q "(cd9660"
python3 scripts/compare-trees.py "$SRC" "$MNT"
(cd "$MNT" && shasum -a 256 -c .burn/SHA256SUMS > /dev/null)
hdiutil detach "$MNT" > /dev/null

# Damages 100 KB in the middle of one file and deletes another.
damage() {
    dd if=/dev/zero of="$1/sub dir/random.bin" bs=1024 seek=1000 count=100 conv=notrunc 2> /dev/null
    rm "$1/hello.txt"
}

step "Recovery data works with par2"
LOG="$WORK/par2.log"
hdiutil attach -readonly -nobrowse -mountpoint "$MNT" "$WORK/test.iso" > /dev/null
par2 verify "-B$MNT" "$MNT/.burn/recovery.par2" >> "$LOG" 2>&1 || failed "par2 verify" "$LOG"
COPY="$WORK/copy"
cp -R "$MNT" "$COPY"
hdiutil detach "$MNT" > /dev/null
chmod -R u+w "$COPY"
damage "$COPY"
if par2 verify "-B$COPY" "$COPY/.burn/recovery.par2" >> "$LOG" 2>&1; then
    echo "par2 didn't notice the damage" >&2
    exit 1
fi
par2 repair "-B$COPY" "$COPY/.burn/recovery.par2" >> "$LOG" 2>&1 || failed "par2 repair" "$LOG"
# par2 keeps the damaged file as random.bin.1, which compare-trees would report.
find "$COPY" -name "*.1" -delete
(cd "$COPY" && shasum -a 256 -c .burn/SHA256SUMS > /dev/null)
python3 scripts/compare-trees.py "$SRC" "$COPY"

step "Repair with burnctl"
hdiutil attach -readonly -nobrowse -mountpoint "$MNT" "$WORK/test.iso" > /dev/null
DISC="$WORK/damaged"
cp -R "$MNT" "$DISC"
hdiutil detach "$MNT" > /dev/null
chmod -R u+w "$DISC"
damage "$DISC"
"$BURNCTL" repair "$DISC" --output "$WORK/repaired"
(cd "$WORK/repaired" && shasum -a 256 -c .burn/SHA256SUMS > /dev/null)
python3 scripts/compare-trees.py "$SRC" "$WORK/repaired"

echo "Recovery data made by par2 itself, so the repair is checked against another encoder:"
REF="$WORK/reference"
cp -R "$SRC" "$REF"
mkdir "$REF/.burn"
(cd "$REF" && find . -type f ! -path "./.burn/*" | sed 's|^\./||' | sort \
    | while IFS= read -r f; do shasum -a 256 "$f"; done > .burn/SHA256SUMS)
(cd "$REF" && find . -type f ! -path "./.burn/*" -print0 \
    | xargs -0 par2 create -q -s4096 -r20 "-B$REF" .burn/recovery.par2)
damage "$REF"
"$BURNCTL" repair "$REF" --output "$WORK/reference-repaired"
(cd "$WORK/reference-repaired" && shasum -a 256 -c .burn/SHA256SUMS > /dev/null)

step "Simulated burns of the same files"
for profile in cd-r dvd-r dvd+r bd-r; do
    "$BURNCTL" simulate-burn "$SRC" --profile "$profile"
done

swift build -c release --package-path Packages/BurnKit --product burnctl > /dev/null
RELEASE="$(swift build -c release --package-path Packages/BurnKit --show-bin-path)/burnctl"

step "Recovery data speed, 256 MB"
mkdir -p "$WORK/speed"
head -c 268435456 /dev/urandom > "$WORK/speed/random.bin"
for percent in 0 10; do
    echo "At ${percent}%: $("$RELEASE" make-iso "$WORK/speed" --output "$WORK/speed.iso" --name Speed \
        --recovery "$percent" | grep seconds)"
done
rm -rf "$WORK/speed" "$WORK/speed.iso"

step "Recovery data memory, 2 GB"
# Memory must stay level however much data there is. Reads that kept every byte in memory made a
# 36 GB disc fill a Mac's memory (hardware run 20).
mkdir -p "$WORK/memory"
head -c 2147483648 /dev/urandom > "$WORK/memory/random.bin"
/usr/bin/time -l "$RELEASE" make-iso "$WORK/memory" --output "$WORK/memory.iso" --name Memory --recovery 10 \
    > /dev/null 2> "$WORK/memory.txt"
PEAK="$(awk '/maximum resident set size/ { print $1 }' "$WORK/memory.txt")"
echo "Peak memory $((PEAK / 1048576)) MB"
rm -rf "$WORK/memory" "$WORK/memory.iso"
if [ "$PEAK" -gt 1073741824 ]; then
    echo "Recovery data used $((PEAK / 1048576)) MB for 2 GB of files. It should stay well under 1 GB." >&2
    exit 1
fi

step "A file over 4 GB through macOS"
BIG="$WORK/big"
mkdir -p "$BIG"
# 4 GiB and 1 MiB, each MiB filled with its own number, so misplaced pieces would show.
python3 -c "
import struct, sys
with open(sys.argv[1], 'wb') as f:
    for i in range(4097):
        f.write(struct.pack('<Q', i) * 131072)
" "$BIG/big.bin"
printf 'small\n' > "$BIG/small.txt"
EXPECTED="$(shasum -a 256 "$BIG/big.bin" | cut -d' ' -f1)"
# Recovery data for 4 GB takes minutes; the speed step measures that.
"$RELEASE" make-iso "$BIG" --output "$WORK/big.iso" --name "Big" --recovery 0
rm "$BIG/big.bin"
hdiutil attach -readonly -nobrowse -mountpoint "$MNT" "$WORK/big.iso" > /dev/null
mount | grep "$MNT" | grep -q "(udf"
test "$(stat -f %z "$MNT/big.bin")" = 4296015872
test "$(shasum -a 256 "$MNT/big.bin" | cut -d' ' -f1)" = "$EXPECTED"
(cd "$MNT" && shasum -a 256 -c .burn/SHA256SUMS > /dev/null)
hdiutil detach "$MNT" > /dev/null

rm -rf "$WORK"
echo
echo "Every check passed in $(( $(date +%s) - started )) s."

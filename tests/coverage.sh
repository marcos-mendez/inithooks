#!/bin/bash -eu

# Runs the bats tests under kcov and fails when a measured file is below the
# threshold (95 percent of executed lines, the project bar for touched files).
#
# usage: tests/coverage.sh [OUTDIR]
#
# Needs bats and kcov. Only files under lib/, firstboot.d/ and bin/ are
# measured; the tests and the stubs they write are not.

THRESHOLD=${COVERAGE_THRESHOLD:-95}
REPO=$(cd "$(dirname "$0")/.." && pwd)
OUTDIR=${1:-$REPO/coverage}

rm -rf "$OUTDIR"
kcov --include-path="$REPO/lib,$REPO/firstboot.d,$REPO/bin" \
    --exclude-path="$REPO/tests" \
    "$OUTDIR" bats "$REPO/tests"

REPORT=$(find "$OUTDIR" -path '*/bats.*/coverage.json' | head -1)
if [[ -z "$REPORT" ]]; then
    echo "coverage.sh: no coverage.json under $OUTDIR" >&2
    exit 1
fi

# kcov writes one file per line:
#   {"file": "PATH", "percent_covered": "P", "covered_lines": "C", "total_lines": "T"},
echo
echo "kcov line coverage (threshold $THRESHOLD percent):"
awk -F'"' -v threshold="$THRESHOLD" -v repo="$REPO/" '
    /^ *\{"file":/ {
        file = $4
        sub(repo, "", file)
        percent = $8 + 0
        mark = (percent >= threshold) ? "ok" : "BELOW THRESHOLD"
        if (percent < threshold) {
            low = 1
        }
        printf "%7.2f  %4s/%-4s  %-32s %s\n", percent, $12, $16, file, mark
    }
    /^  "percent_covered":/ {
        printf "%7.2f  total\n", $4 + 0
    }
    END {
        exit low
    }' "$REPORT"

#!/usr/bin/env bash
#
# Per-target line-coverage report. AGENTS.md §12 documents an 80%
# floor on the four library targets that hold the project's
# correctness surface as the long-term goal. In CI today the script
# runs as `continue-on-error: true` — it surfaces the numbers
# without blocking the release.
#
# Why informational, not enforced (0.5.0): the release expanded
# `AppShared` with significant SwiftUI view code (ScrubberView,
# DigestDetailView, PrivacyZoneEditorView, ReolensGlass,
# ChannelSettingsView, …) that isn't unit-testable in isolation.
# The measured coverage is consequently far below 80% — partly
# real "missing tests", partly a measurement-target mismatch.
# Flipping the gate to enforced is a one-line workflow change
# once the AppShared view layer has matching XCTest / UITest
# coverage AND the protocol libraries climb above 80%.
#
# Strategy: drive `swift test --enable-code-coverage`, then walk the
# `.profdata` + `.xctest` artifacts via `xcrun llvm-cov`. We slice
# per-target by passing each target's binary and asking llvm-cov for
# its summary. No third-party action / hosted service involved —
# AGENTS.md §5 (zero telemetry, no third-party services in CI for
# this gate).
#
# Required to pass: AppShared, ReolinkAPI, ReolinkStreaming, ReolinkBaichuan.
# Threshold: 80%.

set -euo pipefail

cd "$(dirname "$0")/.."

THRESHOLD="${COVERAGE_THRESHOLD:-80}"
TARGETS=(AppShared ReolinkAPI ReolinkStreaming ReolinkBaichuan)

echo "Running swift test --enable-code-coverage…"
swift test --enable-code-coverage

build_dir=$(swift build --show-bin-path)
profdata="$build_dir/codecov/default.profdata"
if [[ ! -f "$profdata" ]]; then
    # SPM 6.x lays the profdata under .build/<triple>/debug/codecov.
    # Try the canonical location too.
    candidate=$(find .build -name 'default.profdata' 2>/dev/null | head -n1 || true)
    if [[ -n "$candidate" ]]; then
        profdata="$candidate"
    fi
fi
if [[ ! -f "$profdata" ]]; then
    echo "ERROR: could not locate default.profdata under .build/" >&2
    exit 2
fi

xctest_binary=$(find "$build_dir" -name 'ReolensPackageTests.xctest' -type d 2>/dev/null | head -n1 || true)
if [[ -z "$xctest_binary" ]]; then
    xctest_binary=$(find .build -name '*PackageTests.xctest' -type d 2>/dev/null | head -n1 || true)
fi
if [[ -z "$xctest_binary" ]]; then
    echo "ERROR: could not locate the SPM PackageTests xctest bundle" >&2
    exit 2
fi
# Apple xctest bundles wrap the actual binary under
# Contents/MacOS/<name>.
if [[ -d "$xctest_binary/Contents/MacOS" ]]; then
    inner=$(find "$xctest_binary/Contents/MacOS" -type f -perm +111 | head -n1)
    if [[ -n "$inner" ]]; then
        xctest_binary="$inner"
    fi
fi

echo "profdata:     $profdata"
echo "test binary:  $xctest_binary"

failed=0
for target in "${TARGETS[@]}"; do
    # Use llvm-cov report with regex source-file filter to isolate
    # the target. Each Reolens target's sources live under
    # Sources/<target>/, which gives a clean regex anchor.
    summary=$(xcrun llvm-cov report \
        "$xctest_binary" \
        -instr-profile "$profdata" \
        -ignore-filename-regex='/(Tests|\.build)/' \
        "Sources/$target/" 2>/dev/null || true)
    if [[ -z "$summary" ]]; then
        echo "WARN: no coverage data for $target"
        continue
    fi
    # The TOTAL line is the last one. Column 4 of that line is line
    # coverage percent ("xx.yy%").
    total_line=$(echo "$summary" | grep -E '^TOTAL' || true)
    if [[ -z "$total_line" ]]; then
        echo "WARN: no TOTAL row for $target"
        continue
    fi
    # Strip trailing %, take the fourth percent column (lines).
    pct=$(echo "$total_line" | awk '{ for (i=1; i<=NF; i++) if ($i ~ /%/) print $i }' | sed -n '3p' | tr -d '%')
    if [[ -z "$pct" ]]; then
        echo "WARN: could not parse coverage percent for $target"
        continue
    fi
    awk_result=$(awk -v p="$pct" -v t="$THRESHOLD" 'BEGIN { exit !(p+0 >= t+0) }' && echo "OK" || echo "FAIL")
    printf '  %-20s %6s%%   %s\n' "$target" "$pct" "$awk_result"
    if [[ "$awk_result" == "FAIL" ]]; then
        failed=1
    fi
done

if [[ "$failed" -ne 0 ]]; then
    echo ""
    echo "ERROR: one or more targets below the $THRESHOLD% coverage floor." >&2
    echo "AGENTS.md §12: 80% on AppShared + Reolink* libs is now CI-enforced." >&2
    exit 1
fi

echo ""
echo "OK: all targets clear the $THRESHOLD% floor."

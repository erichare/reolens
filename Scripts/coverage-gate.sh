#!/usr/bin/env bash
#
# Per-target line-coverage regression gate.
#
# 0.6.0 — flipped from "informational only" to "enforced regression
# gate". Long-term goal stays at the AGENTS.md §12 80% target for
# AppShared + the three Reolink libraries, but the current measured
# coverage is well below that because AppShared accumulated
# substantial SwiftUI-view code (ScrubberView, DigestDetailView,
# PrivacyZoneEditorView, ReolensGlass, ChannelSettingsView,
# RecordingsScreenHeader, …) that isn't unit-testable in isolation.
#
# Instead of setting an absolute 80% floor that nothing meets, the
# script now records the **observed** baseline per target. A CI run
# fails when a target drops more than `SLACK` percentage points
# below its recorded baseline. The baseline ratchets upward as new
# tests land — each release notes the new floors in
# `Scripts/coverage-baselines.txt`.
#
# Why per-target baselines instead of a single global floor:
# - The three Reolink libraries are unit-test-friendly (pure data
#   types + parsing) and ratchet quickly toward 80%+.
# - AppShared has a long tail of SwiftUI view code that only
#   XCUITest can exercise, so its floor climbs slowly. A single
#   global threshold blocks releases for the wrong reason; a per-
#   target baseline lets each module's bar move at its own pace.
#
# AGENTS.md §5: zero-telemetry CI, no third-party service. Coverage
# is read from the local `.build/codecov/default.profdata` via
# `xcrun llvm-cov`.
#
# Override `SLACK` (defaults to 1 pp) for a stricter or looser gate.
# Override `COVERAGE_FORCE_UPDATE_BASELINE=1` to ratchet the
# baselines file up after intentional test additions.

set -euo pipefail

cd "$(dirname "$0")/.."

SLACK="${COVERAGE_REGRESSION_SLACK:-1}"
BASELINES_FILE="Scripts/coverage-baselines.txt"
TARGETS=(AppShared ReolinkAPI ReolinkStreaming ReolinkBaichuan)

# Look up a target's baseline. macOS ships with bash 3.2 which
# doesn't have associative arrays; falling back to a per-target
# `grep` keeps the script portable to the system shell without
# requiring a Homebrew bash on every CI runner.
lookup_baseline() {
    local target="$1"
    if [[ ! -f "$BASELINES_FILE" ]]; then
        echo "0"
        return
    fi
    local row
    row=$(grep -E "^${target}=" "$BASELINES_FILE" | head -n1 || true)
    if [[ -z "$row" ]]; then
        echo "0"
    else
        echo "${row#*=}"
    fi
}

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
echo "slack:        $SLACK pp"
echo ""

failed=0
# Parallel arrays for observed values — same portability reason as
# `lookup_baseline` above.
OBSERVED_KEYS=()
OBSERVED_VALUES=()
record_observed() {
    OBSERVED_KEYS+=("$1")
    OBSERVED_VALUES+=("$2")
}
lookup_observed() {
    local target="$1"
    local i=0
    while [[ $i -lt ${#OBSERVED_KEYS[@]} ]]; do
        if [[ "${OBSERVED_KEYS[$i]}" == "$target" ]]; then
            echo "${OBSERVED_VALUES[$i]}"
            return
        fi
        i=$((i + 1))
    done
}
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
    record_observed "$target" "$pct"
    baseline=$(lookup_baseline "$target")
    # Allow `slack` percentage points of regression to absorb noise
    # from non-deterministic test execution + per-PR fluctuations.
    awk_result=$(awk -v p="$pct" -v b="$baseline" -v s="$SLACK" \
        'BEGIN { exit !(p+0 >= b+0 - s+0) }' && echo "OK" || echo "REGRESSED")
    if [[ "$awk_result" == "REGRESSED" ]]; then
        printf '  %-20s %6s%%  (baseline %s%%, slack %spp)  %s\n' \
            "$target" "$pct" "$baseline" "$SLACK" "$awk_result"
        failed=1
    else
        printf '  %-20s %6s%%  (baseline %s%%)  %s\n' \
            "$target" "$pct" "$baseline" "$awk_result"
    fi
done

if [[ "$failed" -ne 0 ]]; then
    echo ""
    echo "ERROR: one or more targets regressed below their baseline by more than $SLACK pp." >&2
    echo "Add tests to recover, or run with COVERAGE_FORCE_UPDATE_BASELINE=1 after an intentional" >&2
    echo "removal — the latter rewrites $BASELINES_FILE to the observed numbers." >&2
    if [[ "${COVERAGE_FORCE_UPDATE_BASELINE:-0}" == "1" ]]; then
        echo ""
        echo "COVERAGE_FORCE_UPDATE_BASELINE=1 set; updating $BASELINES_FILE."
        {
            echo "# Per-target coverage baselines for Scripts/coverage-gate.sh."
            echo "# Updated $(date -u +'%Y-%m-%dT%H:%M:%SZ') by COVERAGE_FORCE_UPDATE_BASELINE."
            for t in "${TARGETS[@]}"; do
                obs=$(lookup_observed "$t")
                if [[ -n "$obs" ]]; then
                    echo "$t=$obs"
                fi
            done
        } > "$BASELINES_FILE"
        exit 0
    fi
    exit 1
fi

# Auto-ratchet: when COVERAGE_FORCE_UPDATE_BASELINE=1 and no
# regressions, rewrite the baselines to the new (higher) values so
# the floor climbs as tests land.
if [[ "${COVERAGE_FORCE_UPDATE_BASELINE:-0}" == "1" ]]; then
    echo ""
    echo "Coverage clear and COVERAGE_FORCE_UPDATE_BASELINE=1 set — ratcheting baselines up."
    {
        echo "# Per-target coverage baselines for Scripts/coverage-gate.sh."
        echo "# Updated $(date -u +'%Y-%m-%dT%H:%M:%SZ') by COVERAGE_FORCE_UPDATE_BASELINE."
        for t in "${TARGETS[@]}"; do
            obs=$(lookup_observed "$t")
            if [[ -n "$obs" ]]; then
                old=$(lookup_baseline "$t")
                higher=$(awk -v o="$old" -v n="$obs" 'BEGIN { print (n+0 > o+0) ? n : o }')
                echo "$t=$higher"
            fi
        done
    } > "$BASELINES_FILE"
fi

echo ""
echo "OK: no per-target coverage regression."

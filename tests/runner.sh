#!/usr/bin/env bash
set -euo pipefail

PASS=0
FAIL=0
FAILED_NAMES=()

# tests/test_provision.sh is covered by the test_*.sh glob below; listing it
# twice would spend another full provision run per invocation.
for test_file in tests/linux-*.sh tests/test_*.sh; do
    [ -f "$test_file" ] || continue
    name="$(basename "$test_file" .sh)"
    # Real Docker jobs live in dedicated CI (PZ_HOMELAB_APPS_DISPOSABLE=1 +
    # state under /tmp or RUNNER_TEMP). Never compose-up from this glob.
    if grep -q '^# Disposable CI' "$test_file"; then
        printf '\n--- %s ---\n  %s SKIP (disposable CI only)\n' "$name" "$name"
        continue
    fi
    printf '\n--- %s ---\n' "$name"

    TMP="$(mktemp -d)"
    if bash "$test_file" 2>&1; then
        printf '  %s OK\n' "$name"
        PASS=$((PASS + 1))
    else
        printf '  %s FAIL (exit %d)\n' "$name" $?
        FAIL=$((FAIL + 1))
        FAILED_NAMES+=("$name")
    fi
    rm -rf "$TMP"
done

printf '\n=== RESULTS: %d pass, %d fail ===\n' "$PASS" "$FAIL"
if [ "${#FAILED_NAMES[@]}" -gt 0 ]; then
    printf 'Failed: %s\n' "${FAILED_NAMES[*]}"
    exit 1
fi

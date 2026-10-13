#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' '{"status":"blocked","usageBlocked":true,"blockedReason":"connection-grant-not-enforceable","secretsRedacted":true}'
exit 69

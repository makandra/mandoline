#!/usr/bin/env bash
#
# quota.sh — read the account's 5-hour usage window from Claude Code's own
# (undocumented) OAuth usage endpoint, so the orchestrator can pace itself.
#
# Prints one line:  "<utilization> <resets_at> <resets_in_min>"
#   utilization   = 0-100 (percent of the 5-hour window USED; higher = less headroom)
#   resets_at     = ISO-8601 UTC timestamp when the window resets
#   resets_in_min = whole minutes from now until resets_at (0 if already past),
#                   so callers never do timezone arithmetic against local wall-clock;
#                   "unknown" if the timestamp can't be parsed
# e.g.            "42 2026-07-03T09:50:00Z 137"
#
# NOTE: resets_at is UTC. Prefer resets_in_min for "does the reset fit before X?"
# comparisons — the migration reports elapsed/budget in LOCAL time, so comparing a
# UTC timestamp directly is error-prone.
#
# On ANY failure (no token, curl error, unexpected JSON, 401/429) it prints
#   "unknown unknown unknown"
# and exits 0 — the caller MUST treat "unknown" as "act conservatively"
# (smallest batch, or wait), never as "plenty of quota".
#
# Self-caching (~75s TTL) so repeated calls stay well under the endpoint's
# ~1/3-min rate limit. Cache lives in the target repo's tmp/mandoline/ and holds
# only "<utilization> <resets_at>" — resets_in_min is recomputed on every call so
# it is never stale.
#
# Requires: curl, jq. (macOS also uses `security` for the Keychain.)
set -uo pipefail

CACHE="${MANDOLINE_QUOTA_CACHE:-tmp/mandoline/quota-cache.json}"
TTL="${MANDOLINE_QUOTA_TTL:-75}"

fail() { echo "unknown unknown unknown"; exit 0; }

# Given "<util> <resets_at>", compute whole minutes-until-reset and print all three.
emit() {
  local util="$1" resets_at="$2" reset_epoch now_epoch mins
  reset_epoch=$(date -u -d "$resets_at" +%s 2>/dev/null \
    || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$resets_at" +%s 2>/dev/null || echo "")
  if [ -n "$reset_epoch" ]; then
    now_epoch=$(date -u +%s)
    mins=$(( (reset_epoch - now_epoch + 59) / 60 ))
    [ "$mins" -lt 0 ] && mins=0
  else
    mins="unknown"
  fi
  printf '%s %s %s\n' "$util" "$resets_at" "$mins"
}

# 1. Serve a still-fresh cached reading (keeps us under the endpoint rate limit).
#    The cache holds "<util> <resets_at>"; minutes-until-reset is recomputed here.
if [ -f "$CACHE" ]; then
  mtime=$(stat -c %Y "$CACHE" 2>/dev/null || stat -f %m "$CACHE" 2>/dev/null || echo 0)
  if [ $(( $(date +%s) - mtime )) -lt "$TTL" ]; then
    read -r c_util c_resets _ < "$CACHE" 2>/dev/null || fail
    { [ -n "${c_util:-}" ] && [ -n "${c_resets:-}" ] && [ "$c_util" != "unknown" ]; } || fail
    emit "$c_util" "$c_resets"; exit 0
  fi
fi

# 2. Read the OAuth access token (Linux/Windows: file; macOS: login Keychain).
if [ "$(uname)" = "Darwin" ]; then
  creds=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null) || fail
else
  creds=$(cat "$HOME/.claude/.credentials.json" 2>/dev/null) || fail
fi
token=$(printf '%s' "$creds" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
[ -n "$token" ] || fail

# 3. Query the endpoint. Short timeout so a hung request never stalls the caller
#    (Claude Code itself uses a 5s timeout here).
resp=$(curl -sS --max-time 8 \
  -H "Authorization: Bearer $token" \
  -H "anthropic-beta: oauth-2025-04-20" \
  -H "User-Agent: mandoline-quota" \
  -H "Content-Type: application/json" \
  "https://api.anthropic.com/api/oauth/usage" 2>/dev/null) || fail

out=$(printf '%s' "$resp" | jq -r '
  if (.five_hour.utilization != null) and (.five_hour.resets_at != null)
  then "\(.five_hour.utilization) \(.five_hour.resets_at)"
  else empty end' 2>/dev/null)
[ -n "$out" ] || fail
read -r util resets_at <<<"$out"

# 4. Cache the two raw fields; emit three (minutes recomputed fresh each call).
mkdir -p "$(dirname "$CACHE")" 2>/dev/null || true
printf '%s %s\n' "$util" "$resets_at" > "$CACHE" 2>/dev/null || true
emit "$util" "$resets_at"

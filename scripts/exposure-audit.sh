#!/usr/bin/env bash
# Report what this host exposes outside loopback.
#
# Read-only: nothing is changed. Exit 1 when Docker publishes something outside
# loopback or Funnel is enabled, so it can gate a change.
set -uo pipefail

findings=0
section() { printf '\n== %s ==\n' "$1"; }

section "listening outside loopback (informational)"
outside=$(ss -tln 2>/dev/null | awk 'NR>1 && $4 !~ /^127\./ && $4 !~ /^\[::1\]/ {print $4}' | sort -u)
if [ -n "$outside" ]; then printf '%s\n' "$outside"; else echo none; fi

section "docker publishing outside loopback"
if command -v docker >/dev/null 2>&1; then
  wide=$(docker ps --format '{{.Names}}  {{.Ports}}' 2>/dev/null | grep -- '->' | grep -v '127\.0\.0\.1:' || true)
  if [ -n "$wide" ]; then
    printf '%s\n' "$wide"
    findings=$((findings + $(printf '%s\n' "$wide" | grep -c .)))
  else
    echo none
  fi
else
  echo "docker not installed"
fi

section "tailscale serve"
if command -v tailscale >/dev/null 2>&1; then
  tailscale serve status 2>/dev/null || echo "not configured"
else
  echo "tailscale not installed"
fi

section "tailscale funnel (must be empty)"
if command -v tailscale >/dev/null 2>&1; then
  if tailscale funnel status --json 2>/dev/null | grep -q '"AllowFunnel"'; then
    tailscale funnel status 2>/dev/null
    echo "WARNING: funnel publishes to the internet"
    findings=$((findings + 1))
  else
    echo none
  fi
else
  echo "tailscale not installed"
fi

section "summary"
if [ "$findings" -eq 0 ]; then
  echo "clean: docker stays on loopback and funnel is off"
  exit 0
fi
echo "$findings item(s) outside loopback need a documented owner"
exit 1

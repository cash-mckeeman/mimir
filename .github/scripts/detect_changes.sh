#!/usr/bin/env bash
# detect_changes.sh [--all] < changed-paths
# Prints <package>=true|false for every package job, then ok=true, as GitHub step
# outputs. A path that no row matches selects everything, so a new kind of file
# can never select nothing. Every skip is logged with its reason (stderr).
set -euo pipefail
pkgs="mimir workflows orchestration analytics integration"
for p in $pkgs; do printf -v "sel_$p" false; done
all() { for p in $pkgs; do printf -v "sel_$p" true; done; }
pick() { for p in "$@"; do printf -v "sel_$p" true; done; }
if [ "${1:-}" = --all ]; then all; else
  while IFS= read -r path; do
    [ -z "$path" ] && continue
    case "$path" in
      mimir/*)               pick mimir orchestration integration ;;
      mimir_workflows/*)     pick workflows orchestration integration ;;
      mimir_orchestration/*) pick orchestration integration ;;
      mimir_analytics/*)     pick analytics integration ;;
      integration/*)         pick integration ;;
      README.md)             ;;  # the root README alone: the hygiene gate covers it
      mix.exs|.github/*|.hygiene/*|.githooks/*|.gitignore|LICENSE) all ;;
      *) echo "detect-changes: '$path' matches no row; running everything" >&2; all ;;
    esac
  done
fi
for p in $pkgs; do
  v="sel_$p"
  [ "${!v}" = true ] || echo "detect-changes: skipping $p: no changed path selects it" >&2
  echo "$p=${!v}"
done
echo "ok=true"

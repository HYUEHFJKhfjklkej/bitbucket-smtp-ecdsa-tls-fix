#!/usr/bin/env bash
# Shared helpers. Source this AFTER sourcing config.env.
# Enforces the prod-safety rules: backup-before-edit, honest stop/start,
# verify-against-process (not just the file).

set -u

# --- locate & load config -------------------------------------------------
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -z "${BB_HOST:-}" ]]; then
  if [[ -f "${_here}/config.env" ]]; then
    # shellcheck disable=SC1091
    source "${_here}/config.env"
  else
    echo "ERROR: ${_here}/config.env not found. Run: cp config.env.example config.env && edit it." >&2
    exit 1
  fi
fi

# --- pretty output ---------------------------------------------------------
c_hdr() { printf '\n\033[1;36m===== %s =====\033[0m\n' "$*"; }
c_ok()  { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
c_warn(){ printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
c_err() { printf '\033[1;31m[err]\033[0m %s\n' "$*" >&2; }

# --- confirm gate (every mutating action goes through this) ---------------
confirm() {
  local prompt="${1:-Proceed?}"
  printf '\033[1;35m>>> %s\033[0m [type YES to continue] ' "$prompt"
  local a; read -r a
  [[ "$a" == "YES" ]] || { c_warn "aborted by user"; exit 2; }
}

# --- timestamped backup BEFORE any file edit ------------------------------
backup_file() {
  local f="$1"
  [[ -f "$f" ]] || { c_err "no such file to back up: $f"; return 1; }
  local b="${f}.bak-$(date +%F-%H%M%S)"
  cp -p "$f" "$b" && c_ok "backup: $b"
}

# --- PROD RESTART: honest stop -> wait for death -> start -----------------
# Never uses `systemctl restart` (unreliable through the LSB wrapper).
bb_alive() { pgrep -f '[a]tlassian.bitbucket' >/dev/null 2>&1 || pgrep -f '[b]itbucket' >/dev/null 2>&1; }

bb_stop_start() {
  c_warn "PRODUCTION RESTART — web + git push/pull + PR will be DOWN ~1-3 min."
  confirm "Stop Bitbucket now?"

  c_hdr "Stopping Bitbucket"
  systemctl stop atlbitbucket || "$BB_INITD" stop || true

  c_hdr "Waiting for process to actually die"
  for i in $(seq 1 60); do
    if bb_alive; then sleep 2; printf '.'; else break; fi
  done
  echo
  if bb_alive; then
    c_err "process still alive after wait — NOT starting. Investigate manually:"
    ps aux | grep '[b]itbucket'
    exit 1
  fi
  c_ok "process is gone (ps clean)"

  c_hdr "Starting Bitbucket"
  systemctl start atlbitbucket || "$BB_INITD" start
  c_ok "start issued — tail the log to watch it come up:"
  echo "    tail -f $BB_APP_LOG"
}

# --- verify a JVM arg actually reached the RUNNING process ----------------
# Usage: assert_in_process 'mail.smtp.starttls'   (regex)
assert_in_process() {
  local pat="$1"
  c_hdr "Checking RUNNING process for: $pat"
  if ps aux | grep '[b]itbucket' | tr ' ' '\n' | grep -E -- "$pat"; then
    c_ok "present in live process"
  else
    c_warn "NOT found in live process args (it may be a file-only change, or restart didn't pick it up)"
  fi
}

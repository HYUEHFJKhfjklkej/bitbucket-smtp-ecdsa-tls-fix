#!/usr/bin/env bash
# ============================================================================
# 11-jre-rollback.sh — undo exactly what 10-jre-swap.sh did, using the manifest
# it wrote. Restores the original JRE at $BB_JRE and restarts Bitbucket.
# Never deletes the staged new JRE (kept for a quick re-swap).
#
# Usage:
#   scripts/11-jre-rollback.sh          # roll back using the manifest
#   scripts/11-jre-rollback.sh status   # show what would be rolled back
# ============================================================================
source "$(dirname "$0")/../lib/common.sh"

MANIFEST="${BB_INSTALL}/.jre-swap-manifest"

[[ -f "$MANIFEST" ]] || { c_err "no manifest at ${MANIFEST} — nothing recorded to roll back.
  (If you swapped by hand, restore the old JRE manually, e.g. a ${BB_JRE}.orig-* dir.)"; exit 1; }

# shellcheck disable=SC1090
source "$MANIFEST"   # defines: ts bb_jre orig_type orig_target backup_path new_jre
BB_JRE="${bb_jre:-$BB_JRE}"

show() {
  c_hdr "Manifest (${MANIFEST})"; cat "$MANIFEST"
  c_hdr "Current ${BB_JRE}"
  [[ -L "$BB_JRE" ]] && echo "    symlink -> $(readlink "$BB_JRE")"
  [[ -e "$BB_JRE" ]] && "${BB_JRE}/bin/java" -version 2>&1 | sed 's/^/    now: /'
  if [[ "$orig_type" == "dir" ]]; then
    if [[ -d "$backup_path" ]]; then c_ok "backup present: ${backup_path}"
    else c_err "backup MISSING: ${backup_path} — cannot auto-restore the original dir."; fi
  else
    c_ok "original was a symlink -> ${orig_target} (will restore that target)"
  fi
}

show
[[ "${1:-}" == "status" ]] && exit 0

# --- preflight: make sure we can actually restore before we move anything ---
if [[ "$orig_type" == "dir" && ! -d "$backup_path" ]]; then
  c_err "original JRE backup ${backup_path} is gone — refusing to roll back blind."; exit 1
fi
if [[ "$orig_type" == "symlink" && -z "$orig_target" ]]; then
  c_err "manifest has no original symlink target — cannot restore."; exit 1
fi

c_warn "This restores the ORIGINAL bundled JRE and RESTARTS Bitbucket."
confirm "Roll back the JRE at ${BB_JRE} now ?"

ts="$(date +%F-%H%M%S)"

# move the swapped-in JRE/symlink aside (keep it, never delete)
if [[ -L "$BB_JRE" ]]; then
  rm -f "$BB_JRE" && c_ok "removed swap symlink at ${BB_JRE}"
elif [[ -e "$BB_JRE" ]]; then
  mv "$BB_JRE" "${BB_JRE}.swapped-${ts}" && c_ok "moved current JRE -> ${BB_JRE}.swapped-${ts}"
fi

# restore the original
if [[ "$orig_type" == "symlink" ]]; then
  ln -sfn "$orig_target" "$BB_JRE" && c_ok "restored symlink ${BB_JRE} -> ${orig_target}"
else
  mv "$backup_path" "$BB_JRE" && c_ok "restored original JRE dir from ${backup_path}"
fi

"${BB_JRE}/bin/java" -version 2>&1 | sed 's/^/    restored: /'

# retire the manifest so a future swap starts clean
mv "$MANIFEST" "${MANIFEST}.rolledback-${ts}" && c_ok "manifest retired -> ${MANIFEST}.rolledback-${ts}"

bb_stop_start

c_hdr "Live process java after rollback"
ps aux | grep '[b]itbucket' | tr ' ' '\n' | grep -E '/jre|java$' | head
c_ok "Rollback complete. Staged new JRE left at: ${new_jre:-$NEW_JRE_STAGE} (re-swap with 10-jre-swap.sh)."

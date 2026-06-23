#!/usr/bin/env bash
# STEP 3 — LAST RESORT fallback. Replace Bitbucket's bundled JRE with a known-
# good one copied from Jira (Oracle 8u181). Only do this if step 1/2 could not
# be fixed with a targeted java.security edit.
#
# Strategy: copy Jira's JRE onto the Bitbucket host, then point Bitbucket at it
# by RENAMING the old jre dir (never delete) and symlinking the new one in.
# The old JRE is preserved as jre.orig-<ts> for instant rollback.
#
# Usage: 03-swap-jre.sh {fetch|swap|rollback|verify}
source "$(dirname "$0")/../lib/common.sh"

NEW_JRE_LOCAL="/opt/atlassian/_jre-from-jira"   # staging dir on BB host
JRE_LINK="$BB_JRE"                               # .../bitbucket/<ver>/jre

how_java_resolved() {
  c_hdr "How does the init script resolve Java? (inspect before swapping)"
  grep -nE 'JRE_HOME|JAVA_HOME|JAVACMD|/jre' "$BB_START_SCRIPT" "$BB_INITD" 2>/dev/null
  c_warn "Confirm Bitbucket uses \$BB_INSTALL/jre (this script swaps that path)."
}

case "${1:-}" in
  fetch)
    c_hdr "Copy Jira's JRE onto the Bitbucket host (read-only on Jira side)"
    confirm "rsync ${SSH_USER}@${JIRA_HOST}:${JIRA_JRE}/ -> ${NEW_JRE_LOCAL}/ ?"
    rsync -a --delete "${SSH_USER}@${JIRA_HOST}:${JIRA_JRE}/" "${NEW_JRE_LOCAL}/"
    c_ok "staged at ${NEW_JRE_LOCAL}. Verify it runs:"
    "${NEW_JRE_LOCAL}/bin/java" -version 2>&1
    how_java_resolved
    ;;
  swap)
    [[ -x "${NEW_JRE_LOCAL}/bin/java" ]] || { c_err "run 'fetch' first"; exit 1; }
    how_java_resolved
    c_warn "This renames the current JRE and points Bitbucket at the Jira JRE."
    confirm "Swap JRE at ${JRE_LINK} now (requires a restart afterwards)?"
    ts="$(date +%F-%H%M%S)"
    if [[ -L "$JRE_LINK" ]]; then
      c_ok "current jre is a symlink: $(readlink "$JRE_LINK")"
      ln -sfn "${NEW_JRE_LOCAL}" "$JRE_LINK"
    else
      mv "$JRE_LINK" "${JRE_LINK}.orig-${ts}" && c_ok "old JRE kept at ${JRE_LINK}.orig-${ts}"
      ln -sfn "${NEW_JRE_LOCAL}" "$JRE_LINK"
    fi
    c_ok "symlinked. Now restart:"
    bb_stop_start
    "${JRE_LINK}/bin/java" -version 2>&1
    assert_in_process 'java'   # sanity: process is up
    c_warn "Confirm the LIVE process uses the new java:"
    echo "    ps aux | grep '[b]itbucket' | tr ' ' '\\n' | grep -E '/jre|java\$' | head"
    ;;
  rollback)
    c_hdr "Roll back to the original JRE"
    ls -ld "${JRE_LINK}".orig-* 2>/dev/null || c_warn "no .orig-* backup found (was it a symlink swap?)"
    confirm "Restore the most recent ${JRE_LINK}.orig-* over ${JRE_LINK} ?"
    last="$(ls -dt "${JRE_LINK}".orig-* 2>/dev/null | head -1)"
    [[ -n "$last" ]] || { c_err "nothing to roll back to"; exit 1; }
    [[ -L "$JRE_LINK" ]] && rm -f "$JRE_LINK"
    [[ -e "$JRE_LINK" ]] && mv "$JRE_LINK" "${JRE_LINK}.swapped-$(date +%F-%H%M%S)"
    mv "$last" "$JRE_LINK" && c_ok "restored from $last"
    bb_stop_start
    ;;
  verify)
    c_hdr "Live JRE check"
    "${JRE_LINK}/bin/java" -version 2>&1
    ps aux | grep '[b]itbucket' | tr ' ' '\n' | grep -E '/jre|java$' | head
    ;;
  *)
    echo "Usage: $0 {fetch|swap|rollback|verify}"; exit 1;;
esac

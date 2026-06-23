#!/usr/bin/env bash
# STEP 2 — capture the TLS ClientHello to see whether Bitbucket's Java offers
# any ECDSA cipher suites / elliptic curves. Atlassian's official method.
#
# This REQUIRES a restart (adds -Djavax.net.debug). Two sub-commands:
#   on   -> add debug flag, restart, then you press "Test" in the UI
#   off  -> remove debug flag, restart   (ALWAYS run this when done)
#   read -> extract the ClientHello block from the app log
#
# Usage: 02-ssldebug-clienthello.sh {on|read|off}
source "$(dirname "$0")/../lib/common.sh"

FLAG='-Djavax.net.debug=ssl:handshake'
START="$BB_START_SCRIPT"

add_flag() {
  c_hdr "Add SSL debug flag to JVM_SUPPORT_RECOMMENDED_ARGS"
  grep -n 'JVM_SUPPORT_RECOMMENDED_ARGS' "$START" || { c_err "var not found in $START"; exit 1; }
  if grep -q -- "$FLAG" "$START"; then c_warn "flag already present"; return; fi
  backup_file "$START" || exit 1
  confirm "Append '$FLAG' to JVM_SUPPORT_RECOMMENDED_ARGS in $START ?"
  # append inside the existing quoted value, preserving everything (incl. proxy flags)
  sed -i.tmp -E "s#(JVM_SUPPORT_RECOMMENDED_ARGS=\")#\1${FLAG} #" "$START" && rm -f "${START}.tmp"
  c_ok "flag added. Verify the line:"
  grep -n 'JVM_SUPPORT_RECOMMENDED_ARGS' "$START"
}

remove_flag() {
  c_hdr "Remove SSL debug flag"
  grep -q -- "$FLAG" "$START" || { c_warn "flag not present, nothing to remove"; return; }
  backup_file "$START" || exit 1
  confirm "Remove '$FLAG' from $START ?"
  sed -i.tmp "s# *${FLAG}##g" "$START" && rm -f "${START}.tmp"
  c_ok "flag removed. Verify:"
  grep -n 'JVM_SUPPORT_RECOMMENDED_ARGS' "$START"
}

case "${1:-}" in
  on)
    add_flag
    bb_stop_start
    assert_in_process 'javax.net.debug'
    cat <<EOF

NEXT:
  1) Wait until Bitbucket is up (tail -f $BB_APP_LOG).
  2) In the UI: Admin -> Mail server -> Test  (trigger one handshake).
  3) Run:  $0 read
  4) ALWAYS finish with:  $0 off
EOF
    ;;
  read)
    c_hdr "ClientHello / handshake block from $BB_APP_LOG"
    grep -nE 'ClientHello|Cipher Suites?|elliptic_curves|supported_groups|signature_algorithms|ECDSA|No activated|handshake_failure' "$BB_APP_LOG" | tail -120
    cat <<EOF

WHAT TO CHECK in the output:
  - Cipher Suites list contains at least one *_ECDSA_* suite
  - 'Extension elliptic_curves' / 'supported_groups' is NON-empty (e.g. secp256r1)
  - 'Extension signature_algorithms' includes an *_ECDSA entry
  - look for the smoking gun: 'No activated elliptic curves'
EOF
    ;;
  off)
    remove_flag
    bb_stop_start
    assert_in_process 'javax.net.debug' # expect: NOT found
    c_ok "debug flag removed and process restarted."
    ;;
  *)
    echo "Usage: $0 {on|read|off}"; exit 1;;
esac

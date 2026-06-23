#!/usr/bin/env bash
# STEP 1 — read-only. Compare java.security between broken Bitbucket and
# working Jira to find an EC/ECDSA-disabling difference. No restart, no edits.
#
# Run ON the Bitbucket host (it ssh-es to Jira). Safe to run anytime.
source "$(dirname "$0")/../lib/common.sh"

BB_SEC="${BB_JRE}/lib/security/java.security"
JIRA_SEC="${JIRA_JRE}/lib/security/java.security"
JIRA_LOCAL="/tmp/jira-java.security"

# print full logical property (handles backslash line-continuations)
prop() {
  awk '/^[[:space:]]*#/{next}
       /jdk\.(tls|certpath)\.disabledAlgorithms/{p=1}
       p{printf "%s\n",$0; if($0 !~ /\\[[:space:]]*$/) p=0}' "$1"
}

c_hdr "[1] Bitbucket JRE version + file"
"${BB_JRE}/bin/java" -version 2>&1
ls -l "$BB_SEC"

c_hdr "[2] BITBUCKET: disabledAlgorithms (tls + certpath)"
prop "$BB_SEC"

c_hdr "[3] BITBUCKET: security providers"
grep -E '^[[:space:]]*security\.provider\.' "$BB_SEC"

c_hdr "[4] Pull Jira's java.security locally for comparison"
ssh "${SSH_USER}@${JIRA_HOST}" "${JIRA_JRE}/bin/java -version" 2>&1
ssh "${SSH_USER}@${JIRA_HOST}" "cat ${JIRA_SEC}" > "$JIRA_LOCAL" \
  && c_ok "fetched -> $JIRA_LOCAL ($(wc -l < "$JIRA_LOCAL") lines)" \
  || { c_err "failed to fetch Jira java.security"; exit 1; }

c_hdr "[4b] JIRA: disabledAlgorithms (tls + certpath)"
prop "$JIRA_LOCAL"
c_hdr "[4c] JIRA: security providers"
grep -E '^[[:space:]]*security\.provider\.' "$JIRA_LOCAL"

c_hdr "[5] Full diff (bitbucket vs jira)"
if diff -u "$BB_SEC" "$JIRA_LOCAL"; then
  c_ok "files are IDENTICAL — java.security is not the cause; go to step 2 (ClientHello)."
else
  c_warn "files DIFFER — look for EC/ECDSA/curve/keysize entries present only on Bitbucket."
fi

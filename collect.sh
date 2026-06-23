#!/usr/bin/env bash
# ============================================================================
# collect.sh — ONE-SHOT read-only diagnostic for Bitbucket SMTP handshake_failure.
# Changes NOTHING. No restart. Run on the Bitbucket host as root.
# Edit the 4 vars below, then:   bash collect.sh
# It writes /tmp/bb-mail-diag.txt and prints it. Paste that back.
# ============================================================================

# ---- EDIT THESE (real values; this output is for you, not committed) -------
BB_JRE="/opt/atlassian/bitbucket/5.13.1/jre"
BB_HOME="/data/atlassian/application-data/bitbucket"
JIRA_HOST="10.0.0.37"            ; JIRA_JRE="/opt/atlassian/jira/jre"
RELAY_IP="10.0.0.1"              ; RELAY_PORT="587"   ; RELAY_HOST="mail.relay.example"
SSH_USER="root"
# ----------------------------------------------------------------------------

OUT=/tmp/bb-mail-diag.txt
BB_SEC="$BB_JRE/lib/security/java.security"
JIRA_SEC="$JIRA_JRE/lib/security/java.security"
JIRA_LOCAL=/tmp/jira-java.security

h(){ printf '\n========== %s ==========\n' "$*"; }
# print a full logical property (handles backslash line-continuations)
prop(){ awk '/^[[:space:]]*#/{next}
             /jdk\.(tls|certpath)\.disabledAlgorithms/{p=1}
             p{print; if($0 !~ /\\[[:space:]]*$/) p=0}' "$1"; }

{
echo "Bitbucket SMTP/TLS diagnostic — $(date)"
echo "host: $(hostname)"

h "1. Bitbucket JRE version"
"$BB_JRE/bin/java" -version 2>&1
ls -l "$BB_SEC"

h "2. Bitbucket: jdk.tls/certpath.disabledAlgorithms"
prop "$BB_SEC"

h "3. Bitbucket: security providers"
grep -E '^[[:space:]]*security\.provider\.' "$BB_SEC"

h "4. Bitbucket: AES max key length (JCE unlimited?)"
echo 'print("AES max: "+javax.crypto.Cipher.getMaxAllowedKeyLength("AES"))' \
  | "$BB_JRE/bin/jjs" 2>/dev/null || echo "(jjs not available)"

h "5. Live process — JVM args of interest (mail/tls/ssl/proxy/debug)"
ps aux | grep '[b]itbucket' | tr ' ' '\n' \
  | grep -E 'mail\.smtp|jdk\.tls|ssl|proxy|namedGroups|cipherSuites|javax\.net\.debug' \
  || echo "(none matched / process not running)"

h "6. Relay: what it offers on :$RELAY_PORT (STARTTLS, system OpenSSL)"
echo | openssl s_client -starttls smtp -connect "${RELAY_IP}:${RELAY_PORT}" \
  -servername "$RELAY_HOST" 2>/dev/null \
  | grep -E 'subject=|issuer=|Cipher|Server Temp Key|Public-Key|ASN1 OID|NIST CURVE' | head -20

h "7. Relay: force RSA (expected to FAIL if ECDSA-only)"
echo | openssl s_client -starttls smtp -connect "${RELAY_IP}:${RELAY_PORT}" \
  -cipher 'aRSA' 2>&1 | grep -E 'Cipher|handshake failure|no peer|error' | head -5

h "8. Jira (reference, mail WORKS): version + disabledAlgorithms + providers"
ssh -o BatchMode=no -o ConnectTimeout=8 "${SSH_USER}@${JIRA_HOST}" "${JIRA_JRE}/bin/java -version" 2>&1
if ssh -o ConnectTimeout=8 "${SSH_USER}@${JIRA_HOST}" "cat ${JIRA_SEC}" > "$JIRA_LOCAL" 2>/dev/null; then
  echo "--- jira disabledAlgorithms ---"; prop "$JIRA_LOCAL"
  echo "--- jira providers ---";          grep -E '^[[:space:]]*security\.provider\.' "$JIRA_LOCAL"
else
  echo "(could not fetch Jira java.security over ssh)"
fi

h "9. diff java.security  (bitbucket vs jira)"
if [[ -s "$JIRA_LOCAL" ]]; then
  diff -u "$BB_SEC" "$JIRA_LOCAL" && echo "(identical)"
else
  echo "(jira file unavailable — skipped)"
fi

h "10. Recent mail-log errors"
tail -n 40 "$BB_HOME/log/atlassian-bitbucket-mail.log" 2>/dev/null \
  | grep -E 'TLS|SSL|handshake|MessagingException|Exception' | tail -15
} 2>&1 | tee "$OUT"

echo; echo ">>> saved to $OUT — paste its contents back."

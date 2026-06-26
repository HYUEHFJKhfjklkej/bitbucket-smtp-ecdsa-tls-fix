#!/usr/bin/env bash
# Read-only SMTP/TLS diagnostic — run on the BITBUCKET host as root.
# Touches nothing, no restart. Saves /tmp/diag-bitbucket.txt.
# Override defaults via env, e.g.:  RELAY=msk.elara.ru PORT=587 bash diag-bitbucket.sh
RELAY="${RELAY:-msk.elara.ru}"
PORT="${PORT:-587}"
JRE="${JRE:-/opt/atlassian/bitbucket/5.13.1/jre}"
LOG="${LOG:-/data/atlassian/application-data/bitbucket/log/atlassian-bitbucket-mail.log}"
{
echo "===== BITBUCKET diag $(date) @ $(hostname) ====="
echo "relay: $RELAY:$PORT"
echo "--- java -version ---"; "$JRE/bin/java" -version 2>&1
echo "--- jdk.tls/certpath.disabledAlgorithms ---"; grep -A3 -E 'jdk\.(tls|certpath)\.disabledAlgorithms' "$JRE/lib/security/java.security"
echo "--- security providers (SunEC?) ---"; grep -E '^[[:space:]]*security\.provider\.' "$JRE/lib/security/java.security"
echo "--- AES max ---"; echo 'print("AES="+javax.crypto.Cipher.getMaxAllowedKeyLength("AES"))' | "$JRE/bin/jjs" 2>/dev/null || echo "(jjs n/a)"
echo "--- live process mail/tls args ---"; ps aux | grep '[b]itbucket' | tr ' ' '\n' | grep -E 'mail\.smtp|jdk\.tls|ssl|cipherSuites|namedGroups|starttls' || echo "(none)"
echo "--- (1) what relay offers THIS host ---"; echo | openssl s_client -starttls smtp -connect "$RELAY:$PORT" 2>/dev/null | grep -E 'Protocol|Cipher|Peer signature type|Server Temp Key|Public-Key|NIST CURVE'
echo "--- (2) force TLS1.2 + ECDSA ---"; echo | openssl s_client -starttls smtp -connect "$RELAY:$PORT" -tls1_2 -cipher 'ECDHE-ECDSA' 2>&1 | grep -E 'Protocol|Cipher|handshake failure|no peer'
echo "--- recent mail errors ---"; tail -40 "$LOG" 2>/dev/null | grep -E 'TLS|SSL|handshake|MessagingException|Exception' | tail -10
} 2>&1 | tee /tmp/diag-bitbucket.txt

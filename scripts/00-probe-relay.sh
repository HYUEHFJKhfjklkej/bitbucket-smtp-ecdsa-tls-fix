#!/usr/bin/env bash
# STEP 0 — read-only baseline. Confirm what the relay offers and what the
# Bitbucket JRE can do, without touching anything. Run on the Bitbucket host.
source "$(dirname "$0")/../lib/common.sh"

c_hdr "[1] Reachability"
ping -c2 "$RELAY_IP" 2>&1 | tail -3

c_hdr "[2] What the relay offers on :$RELAY_PORT (STARTTLS, via system OpenSSL)"
echo | openssl s_client -starttls smtp -connect "${RELAY_IP}:${RELAY_PORT}" \
  -servername "$RELAY_HOST" 2>/dev/null \
  | grep -E 'subject=|issuer=|Cipher|Server Temp Key|Public-Key|ASN1 OID|NIST CURVE' | head -20

c_hdr "[3] Force RSA — expected to FAIL if relay is ECDSA-only"
echo | openssl s_client -starttls smtp -connect "${RELAY_IP}:${RELAY_PORT}" \
  -cipher 'aRSA' 2>&1 | grep -E 'Cipher|handshake failure|no peer|error' | head -5

c_hdr "[4] Bitbucket JRE: version + AES key length (JCE unlimited?)"
"${BB_JRE}/bin/java" -version 2>&1
echo 'print("AES max: "+javax.crypto.Cipher.getMaxAllowedKeyLength("AES"))' \
  | "${BB_JRE}/bin/jjs" 2>/dev/null || c_warn "jjs not available in this JRE"

c_hdr "[5] Recent mail errors"
tail -n 30 "$BB_MAIL_LOG" 2>/dev/null | grep -E 'TLS|SSL|handshake|MessagingException' | tail -10

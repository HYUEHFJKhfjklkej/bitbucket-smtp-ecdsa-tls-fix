# bitbucket-smtp-ecdsa-tls-fix

Diagnostic & remediation scripts for a **Bitbucket Server 5.13.1** instance that
stopped sending email after the SMTP relay switched from an **RSA** to an
**ECDSA-only (P-256)** certificate.

## Symptom

`Admin → Mail server → Test` fails with:

```
javax.mail.MessagingException: Could not convert socket to TLS
Caused by: javax.net.ssl.SSLHandshakeException: Received fatal alert: handshake_failure
        at com.sun.mail.smtp.SMTPTransport.startTLS(...)
```

The relay (`:587`, STARTTLS) now negotiates only `ECDHE-ECDSA-*` suites on a
`prime256v1` certificate. `openssl s_client` succeeds; Bitbucket's bundled Java
fails the handshake.

## Leading hypothesis

Bitbucket's bundled JRE is **not offering any ECDSA cipher suites / elliptic
curves** in its ClientHello, so an ECDSA-only relay finds no common cipher →
`handshake_failure`. The most likely root cause is an EC/ECDSA-disabling entry
in the bundled `jre/lib/security/java.security` that is **absent** on the
reference hosts (Jira / Confluence) which mail the same relay successfully.

## Already ruled out

- Network to the relay is fine (ping 0% loss).
- SMTP config in the UI (host/port/user/from/STARTTLS) is correct.
- JCE unlimited / AES-256 is **not** the problem (`getMaxAllowedKeyLength("AES")`
  returns `2147483647`; JRE is 8u172 > 8u161).
- These JVM flags were tried and did **not** help: `mail.smtp.ssl.protocols`,
  `jdk.tls.client.cipherSuites`, `jdk.tls.namedGroups`, `starttls.required`.

## Usage

```bash
cp config.env.example config.env      # fill in REAL hosts/IPs/account (gitignored)
$EDITOR config.env
```

Run on the Bitbucket host (it ssh-es to the reference hosts):

| Script | What | Touches prod? |
|---|---|---|
| `scripts/diag-{bitbucket,confluence,jira}.sh` | Self-contained per-host probe (run as root on each box; `RELAY=` overridable). Compares what the relay offers each host + each JRE's `disabledAlgorithms`/providers | read-only |
| `scripts/00-probe-relay.sh` | Baseline: relay cipher, JRE version, AES length, recent errors | read-only |
| `scripts/01-compare-java-security.sh` | Diff `java.security` vs working Jira (find EC/ECDSA disable) | read-only |
| `scripts/02-ssldebug-clienthello.sh {on\|read\|off}` | Capture ClientHello via `javax.net.debug` | **restart** |
| `scripts/03-swap-jre.sh {fetch\|swap\|rollback\|verify}` | Last resort: swap in Jira's known-good JRE | **restart** |
| `scripts/10-jre-swap.sh {stage\|swap\|verify}` | Back up old JRE + stage replacement (`$NEW_JRE_SRC`) + point Bitbucket at it; writes a manifest | **restart** |
| `scripts/11-jre-rollback.sh [status]` | Undo `10-jre-swap.sh` exactly, using the manifest; restore original JRE | **restart** |

> `10`/`11` are the cleaner, manifest-driven version of `03`: the swap records
> what it changed so the rollback is exact, not a guess. Set `NEW_JRE_SRC` /
> `NEW_JRE_STAGE` in `config.env`. **The replacement JRE must be 8u261+ or
> Java 11 if the relay is TLS 1.3-only** — an older Java 8 (e.g. Jira's 8u181)
> won't fix it. `10-jre-swap.sh stage` validates the JRE and warns about this
> before any restart.

## Hard rules baked into the scripts

- **Production.** Every restart = 1–3 min downtime (web + git + PR). Scripts warn
  and require typing `YES` before any restart or file edit.
- **Backup before every edit** (`file.bak-<timestamp>`).
- **Never delete** the existing JRE or existing JVM flags (esp. the HTTP proxy).
- **Verify against the running process** (`ps`), not just the file.
- **Never `systemctl restart`** — honest `stop` → wait for the process to die →
  `start` (`lib/common.sh:bb_stop_start`).

## Parallel workaround (not automated here)

If mail must come back immediately: ask the mail team to re-enable an RSA
suite on the submission port for Bitbucket's IP, **or** run a local
postfix/msmtp relay (Bitbucket → `localhost:25` no-TLS → postfix does the
ECDSA-TLS outbound with system OpenSSL). Bypasses the Java issue entirely;
needs sign-off.

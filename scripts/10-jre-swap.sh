#!/usr/bin/env bash
# ============================================================================
# 10-jre-swap.sh — back up Bitbucket's bundled JRE, stage the replacement JRE,
# and point Bitbucket at it. Writes a MANIFEST so 11-jre-rollback.sh can undo
# exactly what this did. Production-safe: backup before touch, never delete the
# old JRE, honest stop->start, verify against the live process.
#
#   Source of the replacement JRE = $NEW_JRE_SRC (see config.env):
#     local dir | local .tar.gz/.tgz | remote host:path (rsync)
#
# Usage:
#   scripts/10-jre-swap.sh stage   # only fetch+validate the new JRE (no restart)
#   scripts/10-jre-swap.sh swap    # stage (if needed) + back up + swap + restart
#   scripts/10-jre-swap.sh verify  # show which java the live process uses
# ============================================================================
source "$(dirname "$0")/../lib/common.sh"

MANIFEST="${BB_INSTALL}/.jre-swap-manifest"

# --- stage the replacement JRE into $NEW_JRE_STAGE -------------------------
stage_jre() {
  c_hdr "Stage replacement JRE from: ${NEW_JRE_SRC}"
  if [[ -x "${NEW_JRE_STAGE}/bin/java" ]]; then
    c_ok "already staged at ${NEW_JRE_STAGE}"
  elif [[ "$NEW_JRE_SRC" == *:* && "$NEW_JRE_SRC" != /* ]]; then
    # remote host:path -> rsync (read-only on the source side)
    confirm "rsync ${NEW_JRE_SRC}/ -> ${NEW_JRE_STAGE}/ ?"
    mkdir -p "$NEW_JRE_STAGE"
    rsync -a --delete "${NEW_JRE_SRC%/}/" "${NEW_JRE_STAGE}/"
  elif [[ -f "$NEW_JRE_SRC" && "$NEW_JRE_SRC" =~ \.(tar\.gz|tgz)$ ]]; then
    # local tarball -> extract, then flatten if it unpacked into one subdir
    confirm "extract ${NEW_JRE_SRC} -> ${NEW_JRE_STAGE}/ ?"
    rm -rf "$NEW_JRE_STAGE"; mkdir -p "$NEW_JRE_STAGE"
    tar -xzf "$NEW_JRE_SRC" -C "$NEW_JRE_STAGE"
    if [[ ! -x "${NEW_JRE_STAGE}/bin/java" ]]; then
      local inner; inner="$(find "$NEW_JRE_STAGE" -maxdepth 2 -type f -name java -path '*/bin/java' | head -1)"
      [[ -n "$inner" ]] && NEW_JRE_STAGE="$(cd "$(dirname "$inner")/.." && pwd)"
    fi
  elif [[ -x "${NEW_JRE_SRC%/}/bin/java" ]]; then
    # local dir already containing a JRE -> copy into the stage path
    if [[ "$(cd "${NEW_JRE_SRC}" && pwd)" == "$(cd "${NEW_JRE_STAGE}" 2>/dev/null && pwd)" ]]; then
      c_ok "source already at stage path"
    else
      confirm "copy ${NEW_JRE_SRC}/ -> ${NEW_JRE_STAGE}/ ?"
      rm -rf "$NEW_JRE_STAGE"; cp -a "${NEW_JRE_SRC%/}" "$NEW_JRE_STAGE"
    fi
  else
    c_err "NEW_JRE_SRC is not a usable dir / tarball / host:path: ${NEW_JRE_SRC}"; exit 1
  fi

  [[ -x "${NEW_JRE_STAGE}/bin/java" ]] || { c_err "no runnable java at ${NEW_JRE_STAGE}/bin/java"; exit 1; }
  c_hdr "Replacement JRE version"
  "${NEW_JRE_STAGE}/bin/java" -version 2>&1
  # warn if it can't possibly fix a TLS 1.3-only relay
  local v; v="$("${NEW_JRE_STAGE}/bin/java" -version 2>&1 | head -1)"
  if echo "$v" | grep -qE '1\.8\.0_(1[0-9]{2}|2[0-5][0-9])\b'; then
    c_warn "This is Java 8 < 8u261 — it has NO TLS 1.3. If the relay is TLS1.3-only, this will NOT fix mail. Prefer 8u261+ or Java 11."
  fi
  c_ok "staged & runnable at ${NEW_JRE_STAGE}"
}

case "${1:-}" in
  stage)
    stage_jre
    ;;

  swap)
    [[ -e "$MANIFEST" ]] && { c_err "manifest already exists: $MANIFEST — already swapped? run 11-jre-rollback.sh first."; exit 1; }
    stage_jre

    c_hdr "How does Bitbucket resolve Java? (confirm it uses ${BB_JRE})"
    grep -nE 'JRE_HOME|JAVA_HOME|JAVACMD|/jre' "$BB_START_SCRIPT" "$BB_INITD" 2>/dev/null \
      || c_warn "could not grep start scripts — confirm manually that Bitbucket uses ${BB_JRE}"

    ts="$(date +%F-%H%M%S)"
    c_hdr "Current JRE at ${BB_JRE}"
    if [[ -L "$BB_JRE" ]]; then
      orig_type="symlink"; orig_target="$(readlink "$BB_JRE")"
      c_ok "current jre is a symlink -> ${orig_target}"
      backup_path="(symlink, no copy)"
    elif [[ -d "$BB_JRE" ]]; then
      orig_type="dir"; orig_target=""
      backup_path="${BB_JRE}.orig-${ts}"
      c_warn "current jre is a real directory; it will be RENAMED (never deleted)."
    else
      c_err "no JRE found at ${BB_JRE}"; exit 1
    fi
    "${BB_JRE}/bin/java" -version 2>&1 | sed 's/^/    old: /'

    c_warn "About to: back up old JRE, point ${BB_JRE} at the new one, then RESTART."
    confirm "Proceed with the JRE swap at ${BB_JRE} ?"

    # --- do the swap ---
    if [[ "$orig_type" == "symlink" ]]; then
      ln -sfn "$NEW_JRE_STAGE" "$BB_JRE"
    else
      mv "$BB_JRE" "$backup_path" && c_ok "old JRE preserved at ${backup_path}"
      ln -sfn "$NEW_JRE_STAGE" "$BB_JRE"
    fi
    c_ok "${BB_JRE} -> $(readlink "$BB_JRE")"

    # --- write the manifest BEFORE restart, so rollback works even if start hangs ---
    {
      echo "ts=${ts}"
      echo "bb_jre=${BB_JRE}"
      echo "orig_type=${orig_type}"
      echo "orig_target=${orig_target}"
      echo "backup_path=${backup_path}"
      echo "new_jre=${NEW_JRE_STAGE}"
    } > "$MANIFEST"
    c_ok "manifest written: ${MANIFEST}"

    bb_stop_start

    c_hdr "New JRE version at ${BB_JRE}"
    "${BB_JRE}/bin/java" -version 2>&1
    assert_in_process 'java'
    c_warn "Confirm the LIVE process really uses the new java:"
    echo "    ps aux | grep '[b]itbucket' | tr ' ' '\\n' | grep -E '/jre|java\$' | head"
    c_ok "Done. To undo: scripts/11-jre-rollback.sh"
    ;;

  verify)
    c_hdr "Configured JRE"
    "${BB_JRE}/bin/java" -version 2>&1
    [[ -L "$BB_JRE" ]] && echo "    (symlink -> $(readlink "$BB_JRE"))"
    [[ -e "$MANIFEST" ]] && { c_hdr "Manifest"; cat "$MANIFEST"; }
    c_hdr "Live process java"
    ps aux | grep '[b]itbucket' | tr ' ' '\n' | grep -E '/jre|java$' | head
    ;;

  *)
    echo "Usage: $0 {stage|swap|verify}"; exit 1;;
esac

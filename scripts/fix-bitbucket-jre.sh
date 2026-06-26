#!/usr/bin/env bash
# ============================================================================
# fix-bitbucket-jre.sh
# Заменяет битую bundled-JRE Bitbucket (Oracle 8u172, баг TLS/ECDSA) на
# рабочую (8u181/8u202 с Jira/Confluence). Делает бэкап старой JRE, чинит
# права, честно перезапускает Bitbucket. Откат: rollback-bitbucket-jre.sh
#
# ЗАПУСК на Bitbucket-сервере под root:
#   ./fix-bitbucket-jre.sh /root/jre-8u202.tar.gz     # тарбол (tar czf ... jre)
#   ./fix-bitbucket-jre.sh /opt/atlassian/_jre-new    # или папка с bin/java
# ============================================================================
set -euo pipefail

BB_INSTALL="/opt/atlassian/bitbucket/5.13.1"
BB_JRE="${BB_INSTALL}/jre"
SRC="${1:?укажи путь к новой JRE: тарбол .tar.gz или папка с bin/java}"
TS="$(date +%F-%H%M%S)"
WORK="/opt/atlassian/_jre-stage-${TS}"

say(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
ok(){  printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m[err]\033[0m %s\n' "$*" >&2; exit 1; }
confirm(){ printf '\033[1;35m>>> %s\033[0m [напечатай YES] ' "$*"; read -r a; [ "$a" = YES ] || die "отменено"; }

[ "$(id -u)" = 0 ] || die "запускай под root"
[ -e "$SRC" ]      || die "источник не найден: $SRC"

# --- 1. подготовить новую JRE в WORK ---------------------------------------
say "Готовлю новую JRE из: $SRC"
mkdir -p "$WORK"
if [ -d "$SRC" ] && [ -x "$SRC/bin/java" ]; then
  cp -a "$SRC/." "$WORK/"
elif [ -f "$SRC" ]; then
  tar -xzf "$SRC" -C "$WORK"
  if [ ! -x "$WORK/bin/java" ]; then        # тарбол распаковался в подпапку (jre/)
    inner="$(find "$WORK" -maxdepth 3 -type f -path '*/bin/java' | head -1)"
    [ -n "$inner" ] || die "в тарболе не нашёл bin/java"
    NEW="$(cd "$(dirname "$inner")/.." && pwd)"
    WORK="$NEW"
  fi
else
  die "источник не папка с bin/java и не .tar.gz"
fi
[ -x "$WORK/bin/java" ] || die "нет рабочего $WORK/bin/java"

say "Версия НОВОЙ JRE"
"$WORK/bin/java" -version
ok "новая JRE готова: $WORK"

# --- 2. права под владельца установки ---------------------------------------
OWNER="$(stat -c '%U:%G' "$BB_INSTALL")"
chown -R "$OWNER" "$WORK"
chmod -R a+rX "$WORK"
ok "права выставлены ($OWNER, a+rX)"

say "Текущая (битая) JRE"
"$BB_JRE/bin/java" -version 2>&1 | sed 's/^/    old: /' || true

echo
printf '\033[1;33mБудет: бэкап старой JRE -> %s.orig-%s, установка новой, РЕСТАРТ Bitbucket (даунтайм 1-3 мин).\033[0m\n' "$BB_JRE" "$TS"
confirm "Менять JRE и перезапускать Bitbucket сейчас?"

# --- 3. бэкап + установка (старую НИКОГДА не удаляем) -----------------------
if [ -L "$BB_JRE" ]; then
  printf 'symlink -> %s\n' "$(readlink "$BB_JRE")" > "${BB_JRE}.orig-${TS}.symlink"
  rm -f "$BB_JRE"
  ok "старый symlink сохранён в ${BB_JRE}.orig-${TS}.symlink"
else
  mv "$BB_JRE" "${BB_JRE}.orig-${TS}"
  ok "старая JRE сохранена: ${BB_JRE}.orig-${TS}"
fi
mv "$WORK" "$BB_JRE"
chown -R "$OWNER" "$BB_JRE"; chmod -R a+rX "$BB_JRE"
ok "новая JRE установлена в $BB_JRE"
"$BB_JRE/bin/java" -version 2>&1 | sed 's/^/    new: /'

# --- 4. честный stop -> ждём смерти -> start --------------------------------
bb_alive(){ pgrep -f 'atlassian.bitbucket|[b]itbucket' >/dev/null 2>&1; }

say "Останавливаю Bitbucket"
systemctl stop atlbitbucket 2>/dev/null \
  || /etc/init.d/atlbitbucket stop 2>/dev/null \
  || "$BB_INSTALL/bin/stop-bitbucket.sh" 2>/dev/null || true

say "Жду, пока процесс реально умрёт"
for _ in $(seq 1 60); do bb_alive && { sleep 2; printf '.'; } || break; done; echo
bb_alive && die "процесс не умер — НЕ стартую. Разберись вручную: ps aux | grep bitbucket"
ok "процесс остановлен"

say "Стартую Bitbucket"
systemctl start atlbitbucket 2>/dev/null \
  || /etc/init.d/atlbitbucket start 2>/dev/null \
  || "$BB_INSTALL/bin/start-bitbucket.sh"
ok "старт запущен"

ok "ГОТОВО."
cat <<'EOF'
Проверь:
  1) лог старта:  tail -f /data/atlassian/application-data/bitbucket/log/atlassian-bitbucket.log
  2) живой java:  ps aux | grep '[b]itbucket' | tr ' ' '\n' | grep -E '/jre|java$' | head
  3) Bitbucket -> Admin -> Mail server -> Test  (письмо должно уйти)

Откат, если что:  ./rollback-bitbucket-jre.sh
EOF

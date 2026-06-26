#!/usr/bin/env bash
# ============================================================================
# rollback-bitbucket-jre.sh
# Откатывает fix-bitbucket-jre.sh: возвращает оригинальную bundled-JRE из
# самого свежего бэкапа ${BB_JRE}.orig-* и честно перезапускает Bitbucket.
# Текущую (новую) JRE не удаляет — отодвигает в .replaced-<ts>.
#
# ЗАПУСК на Bitbucket-сервере под root:  ./rollback-bitbucket-jre.sh
# ============================================================================
set -euo pipefail

BB_INSTALL="/opt/atlassian/bitbucket/5.13.1"
BB_JRE="${BB_INSTALL}/jre"
TS="$(date +%F-%H%M%S)"

say(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
ok(){  printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m[err]\033[0m %s\n' "$*" >&2; exit 1; }
confirm(){ printf '\033[1;35m>>> %s\033[0m [напечатай YES] ' "$*"; read -r a; [ "$a" = YES ] || die "отменено"; }

[ "$(id -u)" = 0 ] || die "запускай под root"

# найти самый свежий бэкап
last="$(ls -dt "${BB_JRE}".orig-* 2>/dev/null | grep -v '\.symlink$' | head -1 || true)"
linkbak="$(ls -t "${BB_JRE}".orig-*.symlink 2>/dev/null | head -1 || true)"
[ -n "$last" ] || [ -n "$linkbak" ] || die "бэкап ${BB_JRE}.orig-* не найден — откатывать нечего"

say "Что откатываем"
echo "  текущая JRE: $BB_JRE"
[ -e "$BB_JRE/bin/java" ] && "$BB_JRE/bin/java" -version 2>&1 | sed 's/^/    now: /'
[ -n "$last" ]    && echo "  восстановлю из: $last"
[ -n "$linkbak" ] && echo "  (оригинал был symlink: $(cat "$linkbak"))"

confirm "Вернуть оригинальную JRE и перезапустить Bitbucket?"

# отодвинуть текущую (не удаляем)
if [ -L "$BB_JRE" ]; then
  rm -f "$BB_JRE"; ok "снят текущий symlink"
elif [ -e "$BB_JRE" ]; then
  mv "$BB_JRE" "${BB_JRE}.replaced-${TS}"; ok "текущая JRE отложена: ${BB_JRE}.replaced-${TS}"
fi

# восстановить оригинал
if [ -n "$last" ]; then
  mv "$last" "$BB_JRE"; ok "оригинальная JRE восстановлена из $last"
else
  tgt="$(sed 's/^symlink -> //' "$linkbak")"
  ln -sfn "$tgt" "$BB_JRE"; ok "оригинальный symlink восстановлен -> $tgt"
fi
"$BB_JRE/bin/java" -version 2>&1 | sed 's/^/    restored: /'

# честный stop -> ждём -> start
bb_alive(){ pgrep -f 'atlassian.bitbucket|[b]itbucket' >/dev/null 2>&1; }
say "Останавливаю Bitbucket"
systemctl stop atlbitbucket 2>/dev/null \
  || /etc/init.d/atlbitbucket stop 2>/dev/null \
  || "$BB_INSTALL/bin/stop-bitbucket.sh" 2>/dev/null || true
say "Жду смерти процесса"
for _ in $(seq 1 60); do bb_alive && { sleep 2; printf '.'; } || break; done; echo
bb_alive && die "процесс не умер — НЕ стартую. Разберись вручную."
ok "процесс остановлен"
say "Стартую Bitbucket"
systemctl start atlbitbucket 2>/dev/null \
  || /etc/init.d/atlbitbucket start 2>/dev/null \
  || "$BB_INSTALL/bin/start-bitbucket.sh"
ok "старт запущен — смотри лог: tail -f /data/atlassian/application-data/bitbucket/log/atlassian-bitbucket.log"

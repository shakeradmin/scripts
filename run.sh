#!/bin/bash
# Ручной запуск киоска. ВСЕГДА начинает чистую сессию: прежние AppManager и сам киоск снимаются
# перед стартом нового.
#
# Зачем. Раньше скрипт просто делал `exec /home/shaker/AppManager`, поэтому каждый запуск добавлял
# ещё один супервизор. На машине 002 к 20.09.2026 их накопилось два (один с автозапуска, один от
# ручного прогона). Пока киоск жив, это незаметно — но в момент, когда он падает или его
# перезапускают, КАЖДЫЙ AppManager поднимает свой экземпляр, и два киоска дерутся за
# последовательный порт MCU (порт открывается с TIOCEXCL, проигравший падает).
#
# Что НЕ делается и почему:
#  * никакого `pkill -f` по маске: маска, совпадающая с «ShakerView» или «AppManager», попадает и
#    в текст самого скрипта AppManager, и в командную строку чужих процессов. Сверка идёт по
#    ТОЧНОМУ пути, ровно как в fleetpatch и shakerview-watchdog.sh;
#  * вотчдог не трогается: shakerview-watchdog.sh реагирует только после трёх подряд неудачных
#    проверок с интервалом 60 с (~3 минуты), а перезапуск здесь укладывается в секунды.
set -Eeuo pipefail

export DISPLAY=:0

APPMANAGER=/home/shaker/AppManager
KIOSK=/home/shaker/ShakerView2.0Linux/ShakerView2.0.x86_64
GRACE=10   # сколько секунд ждать после TERM, прежде чем слать KILL

# Себя и своих предков не трогаем ни при каких условиях: скрипт мог быть запущен из обёртки,
# у которой в командной строке тоже есть эти пути.
self_and_ancestors() {
  local p=$$
  while [ -n "$p" ] && [ "$p" -gt 1 ]; do
    printf '%s\n' "$p"
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
  done
}
KEEP="$(self_and_ancestors | tr '\n' ' ')"

is_kept() {
  local pid="$1" k
  for k in $KEEP; do [ "$pid" = "$k" ] && return 0; done
  return 1
}

# Точное совпадение: путь стоит первым словом командной строки либо вторым (когда процесс запущен
# как `/bin/bash /home/shaker/AppManager`).
pids_of() {
  local target="$1"
  ps -eo pid=,args= | awk -v t="$target" '{ pid=$1; $1=""; sub(/^ +/,""); if ($1==t || $2==t) print pid }'
}

collect() {
  local target="$1" pid out=""
  for pid in $(pids_of "$target"); do
    is_kept "$pid" && continue
    out="$out $pid"
  done
  printf '%s' "$out"
}

# Сначала супервизоры, потом киоск — иначе снятый киоск будет тут же поднят живым AppManager.
OLD_AM="$(collect "$APPMANAGER")"
OLD_KIOSK="$(collect "$KIOSK")"
VICTIMS="$OLD_AM $OLD_KIOSK"

if [ -n "${VICTIMS// /}" ]; then
  echo "run.sh: снимаю прежнюю сессию — AppManager:${OLD_AM:- нет} киоск:${OLD_KIOSK:- нет}"
  # shellcheck disable=SC2086
  kill $VICTIMS 2>/dev/null || true

  waited=0
  while [ "$waited" -lt "$GRACE" ]; do
    alive=""
    for pid in $VICTIMS; do [ -d "/proc/$pid" ] && alive="$alive $pid"; done
    [ -z "${alive// /}" ] && break
    sleep 1
    waited=$((waited + 1))
  done

  alive=""
  for pid in $VICTIMS; do [ -d "/proc/$pid" ] && alive="$alive $pid"; done
  if [ -n "${alive// /}" ]; then
    echo "run.sh: не завершились за ${GRACE}s, шлю KILL:$alive"
    # shellcheck disable=SC2086
    kill -9 $alive 2>/dev/null || true
    sleep 1
  fi
else
  echo "run.sh: прежних сессий нет"
fi

LEFT_AM="$(collect "$APPMANAGER")"
LEFT_KIOSK="$(collect "$KIOSK")"
if [ -n "${LEFT_AM// /}${LEFT_KIOSK// /}" ]; then
  echo "run.sh: ВНИМАНИЕ, что-то уцелело — AppManager:${LEFT_AM:- нет} киоск:${LEFT_KIOSK:- нет}" >&2
fi

echo "run.sh: стартую AppManager"
exec "$APPMANAGER"

#!/bin/bash
# Показывает состояние собранного ядра. Выполняется за секунду.
#
#   ./check-core.sh
#
# Зачем. Libcore.xcframework в git не хранится — он большой и собирается
# скриптом на месте. Поэтому откат версии ядра в исходниках САМ ПО СЕБЕ ничего
# не меняет: на диске остаётся прежняя сборка, и Xcode линкует именно её.
# Ошибка при этом не меняется ни на букву, и выглядит это как «починил, а всё
# то же самое».
set -e

cd "$(dirname "$0")"
FW="Frameworks/Libcore.xcframework"

echo "── Версии ядер в исходниках ──"
(cd core && go list -m -f '   {{.Path}} {{.Version}}' \
    github.com/sagernet/sing-box github.com/xtls/libxray 2>/dev/null) \
    || echo "   не удалось прочитать core/go.mod"

echo ""
echo "── Собранный фреймворк ──"

if [[ ! -d "$FW" ]]; then
  echo "   ❌ $FW отсутствует."
  echo "      Ядро не собрано. Выполни:  ./build-core.sh"
  exit 1
fi

# Проверяем КАЖДЫЙ срез, а не первый попавшийся.
#
# Во фреймворке их два: ios-arm64 для телефона и ios-arm64_x86_64-simulator
# для симулятора. Первый же вариант find отдаёт симуляторный — а линковка
# падает на телефонном, и проверка показывала «всё на месте» при сломанной
# сборке. Ровно на этом я один раз и обманулся.
SLICES=$(find "$FW" -name Libcore -type f)
if [[ -z "$SLICES" ]]; then
  echo "   ❌ Внутри $FW нет библиотеки — сборка оборвалась на середине."
  echo "      Выполни заново:  ./build-core.sh"
  exit 1
fi

BAD=0
for BIN in $SLICES; do
  SLICE=$(basename "$(dirname "$(dirname "$BIN")")")
  SIZE=$(du -h "$BIN" | cut -f1)
  WHEN=$(date -r "$BIN" "+%d.%m %H:%M" 2>/dev/null || echo "?")

  if nm -a "$BIN" 2>/dev/null | grep -q "http2.(\*Transport)"; then
    MARK="символы http2 на месте"
  else
    MARK="⚠️ символов http2 НЕТ — линковка упадёт"
    BAD=1
  fi

  printf "   %-34s %6s  %s  %s\n" "$SLICE" "$SIZE" "$WHEN" "$MARK"
done

if [[ $BAD -eq 1 ]]; then
  echo ""
  echo "   Пересобери ядро:  ./build-core.sh"
fi

echo ""
echo "Если время сборки — ДО последнего git pull, ядро устарело:"
echo "изменения в исходниках попадут в приложение только после ./build-core.sh"

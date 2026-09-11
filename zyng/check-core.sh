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

BIN="$(find "$FW" -name Libcore -type f | head -1)"
if [[ -z "$BIN" ]]; then
  echo "   ❌ Внутри $FW нет библиотеки — сборка оборвалась на середине."
  echo "      Выполни заново:  ./build-core.sh"
  exit 1
fi

SIZE=$(du -h "$BIN" | cut -f1)
WHEN=$(date -r "$BIN" "+%d.%m %H:%M" 2>/dev/null || echo "?")
echo "   файл:   $BIN"
echo "   размер: $SIZE"
echo "   собран: $WHEN"

# Тот самый символ, на котором падала линковка после обновления Xray.
if nm -a "$BIN" 2>/dev/null | grep -q "http2.(\*Transport)"; then
  echo "   http2:  символы на месте"
else
  echo "   http2:  ⚠️ символов нет — линковка расширения упадёт"
  echo "           Пересобери ядро:  ./build-core.sh"
fi

echo ""
echo "Если «собран» — это время ДО последнего git pull, ядро устарело:"
echo "изменения в исходниках попадут в приложение только после ./build-core.sh"

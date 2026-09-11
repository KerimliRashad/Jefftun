#!/bin/bash
# Собирает Libcore.xcframework — ОБА ядра одной библиотекой.
#
# Запускать один раз (и потом только при обновлении ядер):
#   ./build-core.sh
#
# Почему одной, а не двумя.
#
# gomobile кладёт в каждую собранную библиотеку полную копию среды выполнения
# Go. Две такие библиотеки в одном бинарнике линковщик не принимает: он падает
# на дубликатах __cgo_topofstack, _crosscall2, _IncGoRef и прочих внутренностей
# Go. Поэтому оба ядра сведены в один модуль (папка core/) и собираются вместе —
# среда выполнения получается одна.
#
# Что внутри:
#   • sing-box (Libbox*)  — держит туннель: пакеты, TCP/IP-стек, DNS;
#   • Xray     (LibXray*) — исполняет транспорт xhttp, которого в sing-box нет.
#
# Занимает 10–25 минут. Результат кладётся в Frameworks/Libcore.xcframework
# и в git не попадает — он большой и пересобирается этой командой.
set -e

cd "$(dirname "$0")"
ROOT="$PWD"
OUT="$ROOT/Frameworks"
SRC="$ROOT/core"

# ВАЖНО: форк gomobile от SagerNet, а не оригинальный golang.org/x/mobile.
# sing-box собирается только им, и он же прописан в core/go.mod.
GOMOBILE_PKG="github.com/sagernet/gomobile"

# --- Проверки инструментов -------------------------------------------------

if ! command -v go >/dev/null 2>&1; then
  echo "❌ Нужен Go. Поставь: brew install go"
  exit 1
fi

export PATH="$PATH:$(go env GOPATH)/bin"

DEVDIR="$(xcode-select -p 2>/dev/null || true)"
if [[ "$DEVDIR" != *"Xcode.app"* ]]; then
  echo "❌ Сейчас выбраны Command Line Tools, а нужен полный Xcode."
  echo "   Выполни:  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  exit 1
fi

cd "$SRC"

echo "→ Версии ядер:"
echo "   sing-box: $(go list -m -f '{{.Version}}' github.com/sagernet/sing-box)"
echo "   libXray:  $(go list -m -f '{{.Version}}' github.com/xtls/libxray)"

# --- gomobile --------------------------------------------------------------

echo "→ Устанавливаю gomobile (форк SagerNet)…"
go install -v "$GOMOBILE_PKG/cmd/gomobile@latest"
go install -v "$GOMOBILE_PKG/cmd/gobind@latest"
export PATH="$PATH:$(go env GOPATH)/bin"
hash -r

echo "→ Инициализирую gomobile…"
gomobile init

# --- Сборка ----------------------------------------------------------------

echo "→ Проверяю, что модуль вообще собирается…"
# Дешёвая проверка перед долгой сборкой: ошибки в зависимостях видно сразу,
# а не через двадцать минут в виде невнятного отказа линковщика.
go build ./... || { echo "❌ Модуль не собирается — см. ошибки выше"; exit 1; }

echo "→ Собираю Libcore.xcframework (это надолго, 10–25 минут)…"

mkdir -p "$OUT"

# Старый фреймворк удаляем ЦЕЛИКОМ, а не пишем поверх.
#
# Иначе выходит смесь: gomobile обновляет часть файлов, прежние остаются, и
# Xcode линкует старый архив с новыми заголовками. Проявляется это как
# «Undefined symbol: _golang.org/x/net/http2.(*Transport)» — символа нет,
# потому что половина библиотеки от предыдущей версии ядра.
rm -rf "$OUT/Libcore.xcframework"

# Кэш сборки Go для iOS тоже чистим: при смене версии ядра в нём остаются
# объектные файлы от старых зависимостей, и линковщик берёт их.
go clean -cache >/dev/null 2>&1 || true

# Набор тегов = протоколы, которые попадут в sing-box. Соответствует мобильной
# сборке из его Makefile. На libXray теги не влияют.
TAGS="with_gvisor,with_quic,with_dhcp,with_wireguard,with_utls,with_clash_api"

# Два пакета в одной команде — так gomobile и задуман. Имена в Swift остаются
# прежними и не смешиваются: приставку он берёт из имени пакета, поэтому будут
# Libbox* от sing-box и LibXray* от Xray.
#
# -libname=core даёт на выходе Libcore.xcframework (gomobile добавляет «Lib»).
gomobile bind -v \
  -target ios,iossimulator \
  -libname=core \
  -tags "$TAGS" \
  -trimpath -ldflags="-s -w" \
  -o "$OUT/Libcore.xcframework" \
  github.com/sagernet/sing-box/experimental/libbox \
  github.com/xtls/libxray

# gomobile отдаёт фреймворк в формате macOS (Versions/Current/…), а iOS требует
# плоский бандл. Без этого сборка падает на этапе встраивания.
"$ROOT/flatten-framework.sh" Libcore

# Проверяем результат, а не верим на слово.
#
# gomobile умеет завершиться с нулём, оставив неполный фреймворк, — и тогда
# ошибка всплывает только в Xcode, спустя полчаса, в виде ненайденного символа.
# Проверяем ОБА среза: ios-arm64 для телефона и симуляторный.
#
# Брать первый попавшийся нельзя: find отдаёт симуляторный, а линковка падает
# на телефонном — проверка радостно сообщала бы «всё на месте» при сломанной
# сборке.
SLICES=$(find "$OUT/Libcore.xcframework" -name Libcore -type f)
if [[ -z "$SLICES" ]]; then
  echo "❌ Фреймворк собрался неполным: библиотеки внутри нет."
  exit 1
fi

for BIN in $SLICES; do
  # Предупреждаем, но НЕ останавливаем сборку.
  #
  # Внутри статической библиотеки объектные файлы ссылаются друг на друга, и
  # отличить настоящую нехватку от обычной внутренней ссылки надёжно тут
  # нельзя. Окончательный ответ даёт только линковщик Xcode, а ронять из-за
  # догадки получасовую сборку — хуже, чем промолчать: один раз я так уже
  # забраковал исправный фреймворк.
  REF=$(nm -u "$BIN" 2>/dev/null | grep -o "_golang.org/x/net/http2\.[^ ]*" | head -1)
  if [[ -n "$REF" ]] && ! nm "$BIN" 2>/dev/null | grep -q "[TtDdSs] ${REF}$"; then
    echo "⚠️  В срезе $(basename "$(dirname "$(dirname "$BIN")")") символ $REF"
    echo "    упомянут, но не определён. Если Xcode откажется линковать —"
    echo "    причина здесь, и дело в версии ядра Xray в core/go.mod."
  fi
done

echo ""
echo "✅ Готово: $OUT/Libcore.xcframework"
for BIN in $SLICES; do
  echo "   $(basename "$(dirname "$(dirname "$BIN")")"): $(du -h "$BIN" | cut -f1)"
done
echo ""
echo "Дальше:  xcodegen && open Zyng.xcodeproj"
echo ""

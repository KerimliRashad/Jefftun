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

echo ""
echo "✅ Готово: $OUT/Libcore.xcframework"
echo ""
echo "Дальше:  xcodegen && open Zyng.xcodeproj"
echo ""

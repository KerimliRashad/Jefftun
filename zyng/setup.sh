#!/bin/bash
# Генерирует Zyng.xcodeproj из project.yml.
# Запускать из папки zyng: ./setup.sh
set -e

cd "$(dirname "$0")"

if [[ "$PWD" == "$HOME/Desktop"* || "$PWD" == "$HOME/Documents"* || "$PWD" == *"Mobile Documents"* ]]; then
  echo "⚠️  Проект лежит в защищённой папке: $PWD"
  echo "    macOS не даст Xcode туда писать — будет 'Operation not permitted'."
  echo "    Перенеси проект в ~/Developer и запусти скрипт оттуда."
  exit 1
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "→ Устанавливаю XcodeGen…"
  if ! command -v brew >/dev/null 2>&1; then
    echo "❌ Нужен Homebrew. Установи его: https://brew.sh"
    exit 1
  fi
  brew install xcodegen
fi

echo "→ Генерирую Zyng.xcodeproj…"
xcodegen generate

echo ""
echo "✅ Готово. Открывай:  open Zyng.xcodeproj"
echo ""
echo "Осталось сделать один раз в Xcode:"
echo "  1. Таргет Zyng → Signing & Capabilities → выбрать Team"
echo "  2. Таргет ZyngTunnel → Signing & Capabilities → выбрать тот же Team"
echo "  3. ⌘R"
echo ""
echo "Capabilities добавлять НЕ надо — они уже прописаны в .entitlements."

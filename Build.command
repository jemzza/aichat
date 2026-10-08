#!/bin/bash
# Двойной клик в Finder: генерирует проект через XcodeGen,
# собирает его под симулятор и запускает приложение.
# NO_PAUSE=1 ./Build.command — без ожидания клавиши в конце (для CI/агента).

set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(pwd)"
SCHEME="AIChat"
BUNDLE_ID="com.example.aichat.app"
DERIVED="$ROOT/build/DerivedData"
TOOLS="$ROOT/.tools"

pause_and_exit() {
  echo
  if [ "${NO_PAUSE:-0}" != "1" ]; then
    read -n 1 -s -r -p "Нажмите любую клавишу, чтобы закрыть окно..." || true
  fi
  exit "${1:-0}"
}
trap 'echo; echo "❌ Сборка прервалась с ошибкой (строка $LINENO)."; pause_and_exit 1' ERR

echo "==> Проверяю Xcode"
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "❌ Не найден Xcode. Установите Xcode и выполните: sudo xcode-select -s /Applications/Xcode.app"
  pause_and_exit 1
fi
xcodebuild -version | head -1

echo "==> Ищу XcodeGen"
if command -v xcodegen >/dev/null 2>&1; then
  XCODEGEN="$(command -v xcodegen)"
elif [ -x "$TOOLS/xcodegen/bin/xcodegen" ]; then
  XCODEGEN="$TOOLS/xcodegen/bin/xcodegen"
elif command -v brew >/dev/null 2>&1; then
  echo "    Устанавливаю через Homebrew..."
  brew install xcodegen
  XCODEGEN="$(command -v xcodegen)"
else
  echo "    Homebrew нет — скачиваю XcodeGen в .tools/ ..."
  mkdir -p "$TOOLS"
  curl -fsSL -o "$TOOLS/xcodegen.zip" \
    https://github.com/yonaskolb/XcodeGen/releases/latest/download/xcodegen.zip
  unzip -q -o "$TOOLS/xcodegen.zip" -d "$TOOLS"
  rm -f "$TOOLS/xcodegen.zip"
  xattr -dr com.apple.quarantine "$TOOLS" 2>/dev/null || true
  XCODEGEN="$TOOLS/xcodegen/bin/xcodegen"
fi
echo "    $XCODEGEN"

echo "==> xcodegen generate"
"$XCODEGEN" generate --spec project.yml

echo "==> Собираю под симулятор (первый раз дольше: скачиваются SPM-пакеты)"
xcodebuild \
  -project "$SCHEME.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  build | { command -v xcpretty >/dev/null && xcpretty || cat; }
# pipefail + trap ERR: если xcodebuild упадёт, скрипт остановится выше

APP="$DERIVED/Build/Products/Debug-iphonesimulator/$SCHEME.app"
echo "✅ Сборка готова: $APP"

echo "==> Запускаю в симуляторе"
trap - ERR
DEVICE_ID="$(xcrun simctl list devices booted | grep -Eo '[0-9A-F-]{36}' | head -1 || true)"
if [ -z "$DEVICE_ID" ]; then
  DEVICE_ID="$(xcrun simctl list devices available | grep -E '^\s+iPhone' | tail -1 | grep -Eo '[0-9A-F-]{36}' || true)"
  if [ -n "$DEVICE_ID" ]; then
    xcrun simctl boot "$DEVICE_ID" || true
  fi
fi

if [ -n "$DEVICE_ID" ]; then
  open -a Simulator
  xcrun simctl install "$DEVICE_ID" "$APP" \
    && xcrun simctl launch "$DEVICE_ID" "$BUNDLE_ID" \
    && echo "✅ Приложение запущено" \
    || echo "⚠️  Собрано, но запустить в симуляторе не удалось. Откройте $SCHEME.xcodeproj и нажмите Run."
else
  echo "⚠️  Не найден ни один iPhone-симулятор. Добавьте его в Xcode → Settings → Components."
fi

pause_and_exit 0

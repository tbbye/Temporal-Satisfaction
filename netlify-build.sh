#!/usr/bin/env bash
set -euo pipefail

echo "=== Installing Flutter SDK (if needed) ==="
if [ ! -d "$HOME/flutter" ]; then
  git clone --depth 1 -b stable https://github.com/flutter/flutter.git "$HOME/flutter"
fi

export PATH="$HOME/flutter/bin:$PATH"

echo "=== Flutter version info ==="
flutter --version

echo "=== Ensure stable channel & web enabled ==="
flutter channel stable
flutter upgrade --force
flutter config --enable-web
flutter precache --web

echo "=== Fetching Dart & Flutter packages ==="
flutter pub get

echo "=== Building Flutter web app (release) ==="
flutter build web --release

echo "=== Build complete. Web output at build/web ==="

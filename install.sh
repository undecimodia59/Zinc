#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -n "${ZINC_PREFIX:-}" ]; then
  PREFIX="${ZINC_PREFIX}"
  BIN_DIR="${PREFIX}/bin"
  DATA_DIR="${PREFIX}/share"
else
  PREFIX="${HOME}/.local"
  BIN_DIR="${XDG_BIN_HOME:-${PREFIX}/bin}"
  DATA_DIR="${XDG_DATA_HOME:-${PREFIX}/share}"
fi

echo "==> Building Zinc (ReleaseSafe)"
zig build -Doptimize=ReleaseSafe

echo "==> Installing binary to ${BIN_DIR}"
mkdir -p "${BIN_DIR}"
install -m 755 "${PROJECT_DIR}/zig-out/bin/zinc" "${BIN_DIR}/zinc"

echo "==> Installing icon and desktop entry to ${DATA_DIR}"
mkdir -p "${DATA_DIR}/icons/hicolor/256x256/apps"
mkdir -p "${DATA_DIR}/applications"

install -m 644 "${PROJECT_DIR}/resources/icons/hicolor/256x256/apps/zinc.png" \
  "${DATA_DIR}/icons/hicolor/256x256/apps/zinc.png"

cat > "${DATA_DIR}/applications/zinc.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Zinc
Comment=Lightweight Zig + GTK4 IDE
Exec=${BIN_DIR}/zinc %F
Icon=zinc
Terminal=false
Categories=Development;IDE;TextEditor;
StartupNotify=true
EOF

if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -q "${DATA_DIR}/icons/hicolor" || true
fi

if ! echo ":${PATH}:" | grep -q ":${BIN_DIR}:"; then
  echo "==> Note: ${BIN_DIR} is not on PATH. Add it to use 'zinc' from the shell."
fi

echo "==> Done. You can launch Zinc from your app menu or run: ${BIN_DIR}/zinc"

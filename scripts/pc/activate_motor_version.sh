#!/usr/bin/env bash
set -e

if [ $# -ne 1 ]; then
  echo "Uso: $0 NOMBRE_ARCHIVO.bak"
  exit 1
fi

VERSION_FILE="$1"
VERSIONS_DIR="$HOME/robot_cortadora/firmware/esp32_motor/versions"
ACTIVE_MAIN="$HOME/robot_cortadora/firmware/esp32_motor/active/main/main.c"
BACKUP_DIR="$HOME/robot_cortadora/firmware/esp32_motor/notes"

mkdir -p "$BACKUP_DIR"

if [ ! -f "$VERSIONS_DIR/$VERSION_FILE" ]; then
  echo "No existe: $VERSIONS_DIR/$VERSION_FILE"
  exit 1
fi

if [ -f "$ACTIVE_MAIN" ]; then
  cp "$ACTIVE_MAIN" "$BACKUP_DIR/main_before_switch_$(date +%Y%m%d_%H%M%S).c.bak"
fi

cp "$VERSIONS_DIR/$VERSION_FILE" "$ACTIVE_MAIN"

echo "Version activada en motor:"
echo "  $VERSION_FILE"
echo "Copiada a:"
echo "  $ACTIVE_MAIN"

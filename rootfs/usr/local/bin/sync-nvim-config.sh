#!/bin/bash
# Kopiert die read-only gemountete Host-nvim-Config nach ~/.config/nvim des
# Entwicklungs-Users. Läuft als root (Entrypoint, `devbox nvim sync`) und wechselt
# für den Kopiervorgang per setpriv zum User.
set -euo pipefail
USERNAME="${DEVBOX_USER:-dev}"
USER_UID="$(id -u "$USERNAME")"
USER_GID="$(id -g "$USERNAME")"
SRC=/mnt/host/nvim
DST="/home/$USERNAME/.config/nvim"

if [ -z "$(ls -A "$SRC" 2>/dev/null)" ]; then
  echo "[devbox] kein nvim-Config-Mount unter $SRC - nvim läuft mit Default-Config"
  exit 0
fi
setpriv --reuid="$USER_UID" --regid="$USER_GID" --init-groups --inh-caps=-all \
  rsync -a --delete --exclude '.git/' "$SRC/" "$DST/"
echo "[devbox] nvim-Config synchronisiert ($(ls "$SRC" | wc -l) Einträge)"

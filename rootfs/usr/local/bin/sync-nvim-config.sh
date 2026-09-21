#!/bin/bash
# Copies the read-only mounted host nvim config to the dev user's ~/.config/nvim.
# Runs as root (entrypoint, `devbox nvim sync`) and switches to the user via
# setpriv for the copy itself.
set -euo pipefail
USERNAME="${DEVBOX_USER:-dev}"
USER_UID="$(id -u "$USERNAME")"
USER_GID="$(id -g "$USERNAME")"
SRC=/mnt/host/nvim
DST="/home/$USERNAME/.config/nvim"

if [ -z "$(ls -A "$SRC" 2>/dev/null)" ]; then
  echo "[devbox] no nvim config mounted at $SRC - nvim runs with its default config"
  exit 0
fi
setpriv --reuid="$USER_UID" --regid="$USER_GID" --init-groups --inh-caps=-all \
  rsync -a --delete --exclude '.git/' "$SRC/" "$DST/"
echo "[devbox] nvim config synced ($(ls "$SRC" | wc -l) entries)"

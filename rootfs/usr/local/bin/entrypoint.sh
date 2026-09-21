#!/bin/bash
# Läuft als root (im User-Namespace des rootless Podman), richtet Firewall und
# nvim-Config ein und wechselt dann capability-frei zum Entwicklungs-User.
set -euo pipefail

USERNAME="${DEVBOX_USER:-dev}"
USER_UID="$(id -u "$USERNAME")"
USER_GID="$(id -g "$USERNAME")"
HOME_DIR="/home/$USERNAME"

log() { echo "[devbox] $*"; }

# 1. Firewall (braucht NET_ADMIN/NET_RAW, nur hier als root)
if [ "${DEVBOX_FIREWALL:-1}" = "0" ]; then
  log "Firewall DEAKTIVIERT (DEVBOX_FIREWALL=0) - Container hat vollen Netzzugang"
else
  /usr/local/bin/init-firewall.sh
fi

# 2. Volumes gehören dem User (frische Named Volumes übernehmen die Rechte aus dem
#    Image, ältere oder fremde nicht - deshalb nur die Top-Level-Verzeichnisse prüfen)
for d in "$HOME_DIR/.claude" "$HOME_DIR/.local/share/nvim" "$HOME_DIR/.local/state/nvim" \
         "$HOME_DIR/.cargo/registry" "$HOME_DIR/.cargo/git" "$HOME_DIR/.history"; do
  [ -d "$d" ] || continue
  if [ "$(stat -c %u "$d")" != "$USER_UID" ]; then
    chown "$USER_UID:$USER_GID" "$d"
  fi
done

# 3. nvim-Config vom Host (read-only gemountet) in den Container kopieren.
#    Kopie statt Direkt-Mount: lazy.nvim darf das Lockfile schreiben, und der
#    Container kann die Host-Config nicht verändern. Nachziehen: `devbox sync`.
/usr/local/bin/sync-nvim-config.sh

touch /run/devbox.ready
log "bereit - User $USERNAME ($USER_UID:$USER_GID), Workspace /workspace"

# 4. Alle Capabilities dauerhaft abwerfen (auch aus dem Bounding-Set) und Hauptprozess starten
exec setpriv --reuid="$USER_UID" --regid="$USER_GID" --init-groups \
     --inh-caps=-all --bounding-set=-all \
     env HOME="$HOME_DIR" USER="$USERNAME" LOGNAME="$USERNAME" "$@"

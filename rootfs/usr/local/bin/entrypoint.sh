#!/bin/bash
# Runs as root (inside the user namespace of rootless Podman), sets up the
# firewall and the nvim config, then drops to the dev user without capabilities.
set -euo pipefail

USERNAME="${DEVBOX_USER:-dev}"
USER_UID="$(id -u "$USERNAME")"
USER_GID="$(id -g "$USERNAME")"
HOME_DIR="/home/$USERNAME"

log() { echo "[devbox] $*"; }

# 1. Firewall (needs NET_ADMIN/NET_RAW, root only here)
if [ "${DEVBOX_FIREWALL:-1}" = "0" ]; then
  log "firewall DISABLED (DEVBOX_FIREWALL=0) - the container has full network access"
else
  /usr/local/bin/init-firewall.sh
fi

# 2. Volumes belong to the user (fresh named volumes inherit the ownership from
#    the image, older or foreign ones do not - so only check the top-level dirs)
for d in "$HOME_DIR/.claude" "$HOME_DIR/.local/share/nvim" "$HOME_DIR/.local/state/nvim" \
         "$HOME_DIR/.cargo/registry" "$HOME_DIR/.cargo/git" "$HOME_DIR/.history"; do
  [ -d "$d" ] || continue
  if [ "$(stat -c %u "$d")" != "$USER_UID" ]; then
    chown "$USER_UID:$USER_GID" "$d"
  fi
done

# 3. Copy the host's nvim config (mounted read-only) into the container.
#    A copy instead of a direct mount: lazy.nvim may write its lockfile, and the
#    container cannot modify the host config. Refresh with `devbox nvim sync`.
/usr/local/bin/sync-nvim-config.sh

touch /run/devbox.ready
log "ready - user $USERNAME ($USER_UID:$USER_GID), workspace /workspace"

# 4. Drop all capabilities for good (bounding set included) and start the main process
exec setpriv --reuid="$USER_UID" --regid="$USER_GID" --init-groups \
     --inh-caps=-all --bounding-set=-all \
     env HOME="$HOME_DIR" USER="$USERNAME" LOGNAME="$USERNAME" "$@"

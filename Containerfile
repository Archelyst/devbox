# devbox: sandbox for Claude Code + Neovim + Rust (rootless Podman)
FROM docker.io/library/debian:bookworm-slim

ARG TZ=Europe/Berlin
ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=1000
ARG NODE_VERSION=24.13.1
ARG NVIM_VERSION=v0.11.6
ARG RUST_TOOLCHAIN=stable

ENV TZ=$TZ \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    DEBIAN_FRONTEND=noninteractive

# --- System packages -----------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl wget gnupg2 xz-utils unzip zip jq \
    git git-lfs gh openssh-client \
    zsh tmux less procps man-db tree rsync \
    build-essential pkg-config cmake clang lld libssl-dev \
    python3 python3-venv python3-pip \
    ripgrep fd-find fzf bat \
    iptables ipset iproute2 dnsutils aggregate \
  && rm -rf /var/lib/apt/lists/* \
  && ln -s /usr/bin/fdfind /usr/local/bin/fd \
  && ln -s /usr/bin/batcat /usr/local/bin/bat

# --- Node (for nvim plugins, Mason, npm) ---------------------------------------
RUN ARCH=$(dpkg --print-architecture) \
  && case "$ARCH" in amd64) NARCH=x64;; arm64) NARCH=arm64;; *) echo "unsupported arch $ARCH"; exit 1;; esac \
  && curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NARCH}.tar.xz" \
     | tar -xJ -C /usr/local --strip-components=1 --no-same-owner \
  && rm -f /usr/local/CHANGELOG.md /usr/local/LICENSE /usr/local/README.md \
  && node --version && npm --version

# --- Neovim (release tarball, matching the host version) -----------------------
RUN ARCH=$(dpkg --print-architecture) \
  && case "$ARCH" in amd64) NARCH=x86_64;; arm64) NARCH=arm64;; *) exit 1;; esac \
  && curl -fsSL "https://github.com/neovim/neovim/releases/download/${NVIM_VERSION}/nvim-linux-${NARCH}.tar.gz" \
     | tar -xz -C /opt --no-same-owner \
  && ln -s "/opt/nvim-linux-${NARCH}/bin/nvim" /usr/local/bin/nvim \
  && printf 'luafile /etc/devbox/nvim-clipboard.lua\n' > "/opt/nvim-linux-${NARCH}/share/nvim/sysinit.vim" \
  && nvim --version | head -1

# --- User + directories for mounts/volumes -----------------------------------
RUN groupadd -g "$USER_GID" "$USERNAME" \
  && useradd -m -u "$USER_UID" -g "$USER_GID" -s /bin/zsh "$USERNAME" \
  && mkdir -p /workspace /mnt/host/nvim \
       "/home/$USERNAME/.claude" \
       "/home/$USERNAME/.config/nvim" \
       "/home/$USERNAME/.local/share/nvim" \
       "/home/$USERNAME/.local/state/nvim" \
       "/home/$USERNAME/.local/bin" \
       "/home/$USERNAME/.cargo/registry" \
       "/home/$USERNAME/.cargo/git" \
       "/home/$USERNAME/.history" \
  && chown -R "$USER_UID:$USER_GID" /workspace "/home/$USERNAME"

# --- Userland: Rust, Claude Code, zsh --------------------------------------------
USER $USERNAME
WORKDIR /home/$USERNAME
ENV HOME=/home/$USERNAME \
    PATH=/home/$USERNAME/.local/bin:/home/$USERNAME/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    CLAUDE_CONFIG_DIR=/home/$USERNAME/.claude \
    EDITOR=nvim \
    VISUAL=nvim \
    SHELL=/bin/zsh \
    DEVBOX=1

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
     | sh -s -- -y --no-modify-path --default-toolchain "$RUST_TOOLCHAIN" \
          --profile minimal --component rustfmt --component clippy --component rust-analyzer --component rust-src \
  && rustc --version && cargo --version && rust-analyzer --version

RUN curl -fsSL https://claude.ai/install.sh | bash \
  && claude --version \
  && rm -rf "$HOME/.claude" && mkdir -p "$HOME/.claude"   # keep build state out of the config volume

RUN git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git "$HOME/.oh-my-zsh" \
  && git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions "$HOME/.oh-my-zsh/custom/plugins/zsh-autosuggestions" \
  && git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting "$HOME/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting" \
  && rm -rf "$HOME"/.oh-my-zsh/.git "$HOME"/.oh-my-zsh/custom/plugins/*/.git

COPY --chown=$USER_UID:$USER_GID rootfs/home/dev /home/$USERNAME

WORKDIR /workspace
USER root
# System-wide files last (entrypoint, firewall, allowlist, nvim clipboard shim):
# changing them does not rebuild the toolchain layers.
COPY rootfs/etc /etc
COPY rootfs/usr /usr
RUN chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/init-firewall.sh /usr/local/bin/sync-nvim-config.sh

# terminfo for terminals Debian does not know (otherwise zsh/nvim echo every
# keystroke twice), plus the fzf shell files the slim image drops from /usr/share/doc
RUN curl -fsSL https://raw.githubusercontent.com/wezterm/wezterm/main/termwiz/data/wezterm.terminfo \
      | tic -x -o /usr/share/terminfo - \
  && FZF_VER="$(fzf --version | cut -d' ' -f1)" \
  && mkdir -p /usr/share/doc/fzf/examples \
  && curl -fsSL "https://raw.githubusercontent.com/junegunn/fzf/$FZF_VER/shell/key-bindings.zsh" -o /usr/share/doc/fzf/examples/key-bindings.zsh \
  && curl -fsSL "https://raw.githubusercontent.com/junegunn/fzf/$FZF_VER/shell/completion.zsh"   -o /usr/share/doc/fzf/examples/completion.zsh

# The entrypoint runs briefly as root (firewall, config sync) and then switches
# to $USERNAME via setpriv without any capabilities. Started with --user 0:0.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["sleep", "infinity"]

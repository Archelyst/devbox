# devbox

A sandbox for working with Claude Code: a Podman container with Neovim (your own config), the Rust toolchain and Claude Code, which only sees the current project directory and only reaches an allowlist of hosts.

```sh
cd ~/projects/my-crate
devbox            # zsh in the container, the project lives at /workspace
devbox claude     # straight to Claude Code (with --dangerously-skip-permissions)
devbox nvim src/main.rs
devbox root       # root shell, e.g. for apt install (lost on stop)
devbox nvim sync  # re-read the nvim config from the host
devbox stop
```

The commands follow a scheme: bare verbs act on the sandbox of this directory (`start`, `stop`, `restart`, `status`, `logs`, `list`, `shell`, `root`, `run`), everything else names the topic first and the action second (`nvim sync`, `claude auth`, `firewall reload`, `image build`, `volume list|rm`, `devcontainer init`). For `nvim` and `claude`, the topic without an action starts the program; to pass an argument through anyway, separate it with `--` (`devbox nvim -- sync` opens the file `sync`). `devbox --help` lists everything.

Clipboard: yanking in nvim goes to your terminal via OSC 52 (Windows Terminal, Alacritty, WezTerm, kitty and foot support it; in tmux use `set -g set-clipboard on`). The shim for it lives in `rootfs/etc/devbox/nvim-clipboard.lua` and is loaded through Neovim's `sysinit.vim`, so your own config stays untouched.

The container keeps running in the background until `devbox stop`. For several terminals in the same container just run `devbox` again (or use tmux inside it). Each directory gets its own container.

## Installation

Requirements: rootless Podman (tested with 4.3, Podman 5 should work just as well) and `git`. No podman-compose, no Docker, no root.

```sh
git clone <this repo> ~/devbox
ln -s ~/devbox/bin/devbox ~/.local/bin/devbox
devbox image build    # about 2.2 GB, takes a few minutes
```

On first use, log in to Claude once (`devbox claude`, then `/login`), or take over the existing login from the host:

```sh
devbox claude auth    # copies the login (~/.claude/.credentials.json) and the onboarding state (from ~/.claude.json) into the sandbox volume
```

The login then lives in the volume `devbox-claude` and applies to all projects. Without the onboarding state, Claude would show the setup wizard inside the container and ask for a login there despite valid credentials. The theme comes from `rootfs/home/dev/.claude/settings.json` (default: dark). `devbox volume rm` deletes this volume too; run `devbox claude auth` again afterwards.

## What is in the container

| Component | Source | Configured via |
|---|---|---|
| Debian bookworm-slim | base image | `Containerfile` |
| Rust (stable, clippy, rustfmt, rust-analyzer, rust-src) | rustup in the user's home | build arg `RUST_TOOLCHAIN` |
| Neovim 0.11.6 | release tarball | build arg `NVIM_VERSION` |
| Node 24 | tarball from nodejs.org (for Mason/Copilot) | build arg `NODE_VERSION` |
| Claude Code | official native installer | a rebuild picks up the current version |
| zsh + oh-my-zsh, tmux, ripgrep, fd, fzf, bat, gh, git, clang, cmake | apt | `Containerfile` |

Your `TERM` is passed into the container. If the image does not know the type (no terminfo entry), zsh and nvim echo every keystroke twice; the script then falls back to `xterm-256color`. The entry for WezTerm ships in the image, other terminals can be added in the `Containerfile`.

The user in the container is `dev` (UID 1000). Rootless Podman maps your host user onto it via `--userns=keep-id`, so files in the workspace keep your ownership. If your host user has a different UID, set `DEVBOX_UID`/`DEVBOX_GID` and run `devbox image build` again.

## Mounts and volumes

| Path in the container | Source | Purpose |
|---|---|---|
| `/workspace` | the current directory (rw) | the project |
| `/mnt/host/nvim` | `~/.config/nvim` (ro) | copied to `~/.config/nvim` at startup |
| `~/.claude` | volume `devbox-claude` | Claude's login, settings and sessions |
| `~/.local/share/nvim`, `~/.local/state/nvim` | volumes | lazy.nvim plugins, Mason binaries |
| `~/.cargo/registry`, `~/.cargo/git` | volumes | crate cache |
| `~/.history` | volume | shell history |

The nvim config is copied instead of mounted directly: lazy.nvim may write its lockfile, and nothing in the container can change your host config (which would otherwise run on the host the next time you start `nvim`). `devbox nvim sync` or `devbox restart` picks up changes to the host config. On the first `nvim`, lazy.nvim installs the plugins into the volume and Mason fetches the servers. If you want to edit the config itself: `cd ~/.config/nvim && devbox`, then it is writable at `/workspace`.

Installing extra things: anything inside the home works as `dev` (`cargo install`, `rustup`, `pip install --user`, Mason). For `apt` there is `devbox root`; that is a `podman exec --privileged` as root from the host, and whatever you install there disappears with `devbox stop`. Permanent additions belong in the `Containerfile`, followed by `devbox image build`. The scripts and the allowlist sit in the last layers.

Deliberately not mounted: `~/.ssh`, `~/.gitconfig`, `~/.config/github-copilot` and any other credentials. Your Git name and email come along as environment variables, so `git commit` works while `git push` happens from the host. If you want Copilot in the container, authenticate once with `:Copilot auth` (it lands in the nvim-data volume).

## VS Code / devcontainer

`devbox devcontainer init` drops `.devcontainer/devcontainer.json` into the project. It uses the same image, the same volumes and the same security flags as the script; VS Code (the "Dev Containers" extension) or the `devcontainer` CLI can open the folder in the container with it. Set `"dev.containers.dockerPath": "podman"` in your VS Code settings first and build the image with `devbox image build`. The template lives in `devcontainer/devcontainer.json`.

## Security model

Modelled on `anthropics/claude-code/.devcontainer` and the hardening notes from the Claude docs "Securely deploying AI agents", adapted to rootless Podman:

- **Rootless**: root in the container is an unprivileged sub-UID on the host.
- **Capabilities**: `--cap-drop ALL`; the entrypoint briefly gets `NET_ADMIN`, `NET_RAW`, `SETUID`, `SETGID`, `SETPCAP` and `CHOWN` for the firewall and the user switch, and then starts the main process via `setpriv` with an empty bounding set. `no-new-privileges` prevents setuid binaries or file capabilities from adding anything back. There is no `sudo` in the container.
- **Egress allowlist** (`init-firewall.sh`): iptables + ipset, default REJECT. Allowed are DNS to the resolvers from `/etc/resolv.conf`, the GitHub ranges from `api.github.com/meta` and the hosts from `rootfs/etc/devbox/allowed-domains.txt` (Anthropic, crates.io, static.rust-lang.org, npm, PyPI, Debian). IPv6 is closed entirely so the IPv4 list cannot be bypassed via AAAA. The host gateway is not reachable by default.
- **Resources**: `--memory 8g`, `--pids-limit 4096` (Rust builds need room).
- **Filesystem**: only the project directory is mounted writable.

Limits worth knowing:

- The allowlist resolves hostnames at startup. CDN hosts (crates.io, githubusercontent.com) change IPs; if a download hangs, `devbox firewall reload` (re-resolves) or `devbox restart` helps.
- Allowed hosts are trusted but broad: GitHub alone is enough for exfiltration if Claude had a token. That is why no tokens are mounted.
- Same kernel as the host. For stronger isolation: gVisor or a VM (see the docs).
- Podman `exec` (that is, `devbox run`/`root`/`firewall reload`) is trusted and may do more than the main process: shells started from `devbox` carry the container's capabilities in their bounding set, but none effectively, and `no-new-privileges` keeps them from gaining any. That is intended.
- On WSL, Podman often uses the `vfs` storage driver; the build and the first start are noticeably slower there than with overlay on regular Linux.

## Configuration

Environment variables or `~/.config/devbox/config` (bash syntax, the environment wins):

| Variable | Default | Meaning |
|---|---|---|
| `DEVBOX_IMAGE` | `localhost/devbox:latest` | image |
| `DEVBOX_RUNTIME` | auto-detected | `podman` or `docker` |
| `DEVBOX_MEMORY` / `DEVBOX_PIDS` / `DEVBOX_CPUS` | `8g` / `4096` / unlimited | limits |
| `DEVBOX_FIREWALL` | `1` | `0` turns the allowlist off |
| `DEVBOX_ALLOW_HOST` | `0` | `1` allows connections to the host gateway (dev server on the host) |
| `DEVBOX_EXTRA_DOMAINS` | empty | additional hosts, space separated |
| `DEVBOX_NVIM_CONFIG` | `~/.config/nvim` | nvim config on the host |
| `DEVBOX_PORTS` | empty | `"8080:8080 3000:3000"`, ports published outwards |
| `DEVBOX_MOUNTS` | empty | additional `-v` specs, e.g. `"$HOME/data:/data:ro,z"` |
| `DEVBOX_CLAUDE_ARGS` | `--dangerously-skip-permissions` | arguments for `devbox claude` |
| `DEVBOX_UID` / `DEVBOX_GID` | `1000` | UID/GID in the image (build arg) |

Example `~/.config/devbox/config`:

```sh
DEVBOX_MEMORY=16g
DEVBOX_CPUS=8
DEVBOX_EXTRA_DOMAINS="docs.rs code.claude.com"
```

## Allowing more hosts

The container only reaches the hosts on the allowlist (see the security model). Three ways to open up more:

- **Once, for this container**: `DEVBOX_EXTRA_DOMAINS="docs.rs example.org" devbox`. If the container is already running, `DEVBOX_EXTRA_DOMAINS="docs.rs example.org" devbox firewall reload` reapplies the allowlist immediately, without a restart. The variable has to be given in full every time, as it replaces the previous value.
- **Permanently, for you**: put `DEVBOX_EXTRA_DOMAINS` into `~/.config/devbox/config` (see the example above).
- **Permanently, in the image**: add the hostname to `rootfs/etc/devbox/allowed-domains.txt` (one host per line, `#` for comments) and run `devbox image build`. The rebuild only takes seconds because the file sits in the last layer.

What you give are hostnames, not URLs, and no wildcards; `*.example.org` does not work, every subdomain host has to be listed on its own. The names are resolved to IPv4 addresses at startup (or on `devbox firewall reload`). Whether a host gets through is shown by the startup log (`[firewall] host -> ip`) or by `curl -I https://host` inside the container.

The script also works with Docker instead of Podman (`--userns keep-id` is dropped), but then the host UID has to match the image UID.

## Cleaning up

```sh
devbox list            # all sandbox containers
devbox stop            # the container of the current directory
devbox volume list     # caches, Claude login, nvim plugins
devbox volume rm       # delete all of that (the login is lost)
podman rmi localhost/devbox:latest
```

# devbox

Eine Sandbox für die Arbeit mit Claude Code: ein Podman-Container mit Neovim (eigene Config), Rust-Toolchain und Claude Code, der nur das aktuelle Projektverzeichnis sieht und nur eine Allowlist von Hosts erreicht.

```sh
cd ~/projekte/mein-crate
devbox            # zsh im Container, Projekt liegt unter /workspace
devbox claude     # direkt Claude Code (mit --dangerously-skip-permissions)
devbox nvim src/main.rs
devbox root       # Root-Shell, z. B. für apt install (geht bei stop verloren)
devbox nvim sync  # nvim-Config vom Host neu einlesen
devbox stop
```

Die Befehle folgen einem Schema: bloße Verben betreffen die Sandbox dieses Verzeichnisses (`start`, `stop`, `restart`, `status`, `logs`, `list`, `shell`, `root`, `run`), alles andere nennt zuerst das Thema und dann die Aktion (`nvim sync`, `claude auth`, `firewall reload`, `image build`, `volume list|rm`, `devcontainer init`). Bei `nvim` und `claude` startet das Thema ohne Aktion das Programm; soll ein Argument trotzdem durchgereicht werden, trennt `--` ab (`devbox nvim -- sync` öffnet die Datei `sync`). `devbox --help` zeigt alles.

Zwischenablage: Yank in nvim geht per OSC 52 an dein Terminal (Windows Terminal, Alacritty, WezTerm, kitty, foot können das; in tmux `set -g set-clipboard on`). Der Shim dafür liegt in `rootfs/etc/devbox/nvim-clipboard.lua` und wird über Neovims `sysinit.vim` geladen, deine Config bleibt unberührt.

Der Container läuft im Hintergrund weiter, bis `devbox stop`. Mehrere Terminals in denselben Container: einfach `devbox` erneut aufrufen (oder tmux im Container). Pro Verzeichnis gibt es einen eigenen Container.

## Installation

Voraussetzungen: rootless Podman (getestet mit 4.3, Podman 5 sollte genauso gehen), `git`. Kein podman-compose, kein Docker, kein Root.

```sh
git clone <dieses Repo> ~/devbox
ln -s ~/devbox/bin/devbox ~/.local/bin/devbox
devbox image build    # ca. 2,2 GB, dauert ein paar Minuten
```

Beim ersten Start einmal in Claude einloggen (`devbox claude`, dann `/login`), oder den bestehenden Login vom Host übernehmen:

```sh
devbox claude auth    # kopiert Login (~/.claude/.credentials.json) und Onboarding-Status (aus ~/.claude.json) in das Sandbox-Volume
```

Der Login liegt danach im Volume `devbox-claude` und gilt für alle Projekte. Ohne den Onboarding-Status würde Claude im Container den Einrichtungsassistenten zeigen und dort trotz gültiger Zugangsdaten erneut einen Login verlangen. Das Theme kommt aus `rootfs/home/dev/.claude/settings.json` (Standard: dark). `devbox volume rm` löscht auch dieses Volume, danach `devbox claude auth` erneut ausführen.

## Was im Container ist

| Komponente | Woher | Anpassen über |
|---|---|---|
| Debian bookworm-slim | Basisimage | `Containerfile` |
| Rust (stable, clippy, rustfmt, rust-analyzer, rust-src) | rustup im User-Home | Build-Arg `RUST_TOOLCHAIN` |
| Neovim 0.11.6 | Release-Tarball | Build-Arg `NVIM_VERSION` |
| Node 24 | Tarball von nodejs.org (für Mason/Copilot) | Build-Arg `NODE_VERSION` |
| Claude Code | offizieller Native-Installer | Rebuild holt die aktuelle Version |
| zsh + oh-my-zsh, tmux, ripgrep, fd, fzf, bat, gh, git, clang, cmake | apt | `Containerfile` |

Dein `TERM` wird in den Container durchgereicht. Kennt das Image den Typ nicht (kein terminfo-Eintrag), zeichnen zsh und nvim jede Eingabe doppelt; das Skript weicht dann auf `xterm-256color` aus. Für WezTerm liegt der Eintrag im Image, andere Terminals im `Containerfile` ergänzen.

User im Container ist `dev` (UID 1000). Rootless Podman bildet deinen Host-User per `--userns=keep-id` darauf ab, Dateien im Workspace behalten also deinen Besitzer. Hat dein Host-User eine andere UID: `DEVBOX_UID`/`DEVBOX_GID` setzen und `devbox image build` erneut laufen lassen.

## Mounts und Volumes

| Pfad im Container | Quelle | Zweck |
|---|---|---|
| `/workspace` | aktuelles Verzeichnis (rw) | das Projekt |
| `/mnt/host/nvim` | `~/.config/nvim` (ro) | wird beim Start nach `~/.config/nvim` kopiert |
| `~/.claude` | Volume `devbox-claude` | Login, Settings, Sessions von Claude |
| `~/.local/share/nvim`, `~/.local/state/nvim` | Volumes | lazy.nvim-Plugins, Mason-Binaries |
| `~/.cargo/registry`, `~/.cargo/git` | Volumes | Crate-Cache |
| `~/.history` | Volume | Shell-History |

Die nvim-Config wird kopiert statt direkt gemountet: lazy.nvim darf das Lockfile schreiben, und nichts im Container kann deine Host-Config ändern (die würde beim nächsten `nvim` auf dem Host ausgeführt). Änderungen an der Host-Config holt `devbox nvim sync` oder `devbox restart` nach. Beim ersten `nvim` installiert lazy.nvim die Plugins ins Volume, Mason lädt Server nach. Willst du die Config selbst bearbeiten: `cd ~/.config/nvim && devbox`, dann liegt sie beschreibbar unter `/workspace`.

Etwas nachinstallieren: alles im Home geht als `dev` (`cargo install`, `rustup`, `pip install --user`, Mason). Für `apt` gibt es `devbox root`; das ist ein `podman exec --privileged` als Root vom Host aus, und was du dort installierst, verschwindet mit `devbox stop`. Dauerhaft gehört es ins `Containerfile`, dann `devbox image build`. Skripte und Allowlist liegen in den letzten Layern.

Nicht gemountet, absichtlich: `~/.ssh`, `~/.gitconfig`, `~/.config/github-copilot`, sonstige Credentials. Git-Name und -Mail kommen als Umgebungsvariablen mit, `git commit` funktioniert, `git push` machst du vom Host. Copilot im Container bei Bedarf einmal per `:Copilot auth` anmelden (landet im nvim-data-Volume).

## VS Code / Devcontainer

`devbox devcontainer init` legt `.devcontainer/devcontainer.json` ins Projekt. Sie nutzt dasselbe Image, dieselben Volumes und dieselben Sicherheits-Flags wie das Skript; VS Code (Extension „Dev Containers") oder das `devcontainer`-CLI können den Ordner damit im Container öffnen. Vorher in den VS-Code-Settings `"dev.containers.dockerPath": "podman"` setzen und das Image mit `devbox image build` bauen. Die Vorlage liegt in `devcontainer/devcontainer.json`.

## Sicherheitsmodell

Angelehnt an `anthropics/claude-code/.devcontainer` und die Härtungs-Hinweise aus der Claude-Doku „Securely deploying AI agents", angepasst an rootless Podman:

- **Rootless**: Root im Container ist ein unprivilegierter Sub-UID auf dem Host.
- **Capabilities**: `--cap-drop ALL`; der Entrypoint bekommt kurz `NET_ADMIN`, `NET_RAW`, `SETUID`, `SETGID`, `SETPCAP`, `CHOWN` für Firewall und User-Wechsel und startet den Hauptprozess dann per `setpriv` mit leerem Bounding-Set. `no-new-privileges` verhindert, dass setuid-Binaries oder File-Capabilities wieder etwas hinzufügen. Kein `sudo` im Container.
- **Egress-Allowlist** (`init-firewall.sh`): iptables + ipset, Default REJECT. Erlaubt sind DNS zu den Resolvern aus `/etc/resolv.conf`, die GitHub-Ranges aus `api.github.com/meta` und die Hosts aus `rootfs/etc/devbox/allowed-domains.txt` (Anthropic, crates.io, static.rust-lang.org, npm, PyPI, Debian). IPv6 ist komplett zu, damit die IPv4-Liste nicht per AAAA umgangen wird. Das Host-Gateway ist standardmäßig nicht erreichbar.
- **Ressourcen**: `--memory 8g`, `--pids-limit 4096` (Rust-Builds brauchen Luft).
- **Dateisystem**: Nur das Projektverzeichnis ist beschreibbar gemountet.

Grenzen, die man kennen sollte:

- Die Allowlist löst Hostnamen beim Start auf. CDN-Hosts (crates.io, githubusercontent.com) wechseln IPs; wenn ein Download hängt, hilft `devbox firewall reload` (löst neu auf) oder `devbox restart`.
- Erlaubte Hosts sind vertrauenswürdig, aber breit: GitHub reicht zum Exfiltrieren, wenn Claude ein Token hätte. Deshalb keine Tokens mounten.
- Gleicher Kernel wie der Host. Für stärkere Isolation: gVisor oder VM (siehe Doku).
- Podman-`exec` (also `devbox run`/`root`/`firewall reload`) ist vertrauenswürdig und darf mehr als der Hauptprozess: Shells aus `devbox` tragen die Capabilities des Containers im Bounding-Set, effektiv aber keine, und `no-new-privileges` verhindert, dass sie welche bekommen. Das ist gewollt.
- Unter WSL nutzt Podman oft den `vfs`-Speichertreiber; Build und Erststart sind dort deutlich langsamer als mit Overlay auf einem normalen Linux.

## Konfiguration

Umgebungsvariablen oder `~/.config/devbox/config` (Bash-Syntax, Env gewinnt):

| Variable | Default | Bedeutung |
|---|---|---|
| `DEVBOX_IMAGE` | `localhost/devbox:latest` | Image |
| `DEVBOX_RUNTIME` | automatisch | `podman` oder `docker` |
| `DEVBOX_MEMORY` / `DEVBOX_PIDS` / `DEVBOX_CPUS` | `8g` / `4096` / unbegrenzt | Limits |
| `DEVBOX_FIREWALL` | `1` | `0` schaltet die Allowlist ab |
| `DEVBOX_ALLOW_HOST` | `0` | `1` erlaubt Verbindungen zum Host-Gateway (Dev-Server auf dem Host) |
| `DEVBOX_EXTRA_DOMAINS` | leer | zusätzliche Hosts, leerzeichengetrennt |
| `DEVBOX_NVIM_CONFIG` | `~/.config/nvim` | nvim-Config auf dem Host |
| `DEVBOX_PORTS` | leer | `"8080:8080 3000:3000"`, Ports nach außen |
| `DEVBOX_MOUNTS` | leer | zusätzliche `-v`-Specs, z. B. `"$HOME/daten:/data:ro,z"` |
| `DEVBOX_CLAUDE_ARGS` | `--dangerously-skip-permissions` | Argumente für `devbox claude` |
| `DEVBOX_UID` / `DEVBOX_GID` | `1000` | UID/GID im Image (Build-Arg) |

Beispiel `~/.config/devbox/config`:

```sh
DEVBOX_MEMORY=16g
DEVBOX_CPUS=8
DEVBOX_EXTRA_DOMAINS="docs.rs code.claude.com"
```

## Weitere Hosts erlauben

Der Container erreicht nur die Hosts aus der Allowlist (siehe Sicherheitsmodell). Drei Wege, weitere freizuschalten:

- **Einmalig für diesen Container**: `DEVBOX_EXTRA_DOMAINS="docs.rs example.org" devbox`. Läuft der Container schon: `DEVBOX_EXTRA_DOMAINS="docs.rs example.org" devbox firewall reload` wendet die Allowlist sofort neu an, ohne Neustart. Die Variable muss dabei jedes Mal komplett angegeben werden, sie ersetzt die vorherige.
- **Dauerhaft für dich**: `DEVBOX_EXTRA_DOMAINS` in `~/.config/devbox/config` eintragen (siehe Beispiel oben).
- **Dauerhaft im Image**: Hostname in `rootfs/etc/devbox/allowed-domains.txt` eintragen (eine Zeile pro Host, `#` für Kommentare) und `devbox image build`. Der Rebuild dauert nur Sekunden, weil die Datei im letzten Layer liegt.

Angegeben werden Hostnamen, keine URLs und keine Wildcards; `*.example.org` geht nicht, jeder Subdomain-Host muss einzeln stehen. Die Namen werden beim Start (bzw. bei `devbox firewall reload`) per DNS zu IPv4-Adressen aufgelöst. Ob ein Host durchkommt, zeigt das Startlog (`[firewall] host -> ip`) oder ein `curl -I https://host` im Container.

Mit Docker statt Podman funktioniert das Skript ebenfalls (`--userns keep-id` entfällt), dann muss die Host-UID der Image-UID entsprechen.

## Aufräumen

```sh
devbox list            # alle Sandbox-Container
devbox stop            # Container des aktuellen Verzeichnisses
devbox volume list     # Caches, Claude-Login, nvim-Plugins
devbox volume rm       # alles davon löschen (Login geht verloren)
podman rmi localhost/devbox:latest
```

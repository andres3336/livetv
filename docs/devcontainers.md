# Dev container configuration

One configuration, at `.devcontainer/devcontainer.json`:

```
.devcontainer/
└── devcontainer.json   image, features, capabilities, mounts, hooks
config/
├── post-create.sh      postCreate: tun, extras, netbird, android sdk, opencode
└── netbird-up          postStart: start the daemon, rejoin or enroll
```

The manifest cannot move: Codespaces discovers a configuration only at
`.devcontainer/devcontainer.json`, `.devcontainer/<name>/devcontainer.json` or
`.devcontainer.json` in the repository root. The hook scripts it calls live in
`config/`, which is why `postCreateCommand` reads
`bash config/post-create.sh`.

`opencode.json` at the repository root is OpenCode's own project config, not a
dev container file. It pins `ollama-cloud/deepseek-v4.1-flash` as the default
model and holds no credentials: OpenCode reads `OLLAMA_API_KEY` from the
environment, which is the variable models.dev declares for that provider. It has
to sit at the root (or `.opencode/opencode.json`) because OpenCode discovers
configuration from the working directory upwards, so a copy under `config/` or
`.devcontainer/` would never be read.

`config/netbird-up` keeps no `.sh` extension because the file name doubles as
the installed command: `post-create.sh` copies it to `/usr/local/bin/netbird-up`, so
`sudo netbird-up` is what you type.

GitHub Codespaces and the dev container editor both resolve the default path,
so "Edit container" opens this file directly. There are no alternative configs:
a subdirectory config (`.devcontainer/<name>/devcontainer.json`) only exists to
offer a *choice* of environments, and this repository has one.

## Use it

GitHub → Code → Codespaces → **New with options** → the **Dev container
configuration** dropdown shows a single entry. Pick a machine size and create.

After changing this configuration, use "Codespaces: Rebuild Container". Only a
machine size or region change forces a new codespace.

## What gets installed

`post-create.sh` runs as `postCreateCommand` and is re-entrant: every step is guarded,
so re-running it by hand is safe and a rebuild only downloads what is missing.
Failures are logged and never fatal.

| Component | Source | Footprint |
|---|---|---|
| Base image | `mcr.microsoft.com/devcontainers/base:ubuntu-24.04` | ~1 GB |
| JDK 21 | `ghcr.io/devcontainers/features/java:1` | ~0.3 GB |
| Android cmdline-tools | `dl.google.com`, build auto-detected (fallback `15859902`) | 173 MiB download |
| `platform-tools`, `platforms;android-36`, `build-tools;36.0.0` | same | 133 MiB download |
| NetBird | `pkgs.netbird.io/install.sh` | small |
| opencode | `opencode.ai/install` (installs to `~/.opencode/bin`) | small |
| `jq`, `unzip`, `bzip2`, `netcat-openbsd` | apt | small |

Total environment is roughly 2 GB on disk. Emulator images, system images and
the NDK are deliberately **not** installed — those are the multi-gigabyte part
of an Android SDK and are not needed to build.

## Requirements

Already declared in `devcontainer.json`:

| Requirement | Why |
|---|---|
| `capAdd: NET_ADMIN, NET_RAW, SYS_RESOURCE, MKNOD` | kernel-mode WireGuard, and creating the tun node |
| `init: true` | PID 1 is docker-init, not systemd, so NetBird runs detached |
| `/dev/net/tun` | created by `mknod c 10 200`; without it NetBird falls back to netstack |
| volume `/var/lib/netbird` | peer identity survives rebuilds, so a setup key is spent once per machine |
| volume `/opt/gradle-cache` | Gradle caches survive rebuilds |

Outbound HTTPS is required to `mcr.microsoft.com`, `ghcr.io` (Java feature),
`dl.google.com` (cmdline-tools), `pkgs.netbird.io` (installer), `opencode.ai`
and the distro apt mirrors.

Machine size: 2-core / 8 GB is enough to create the environment. Use 4-core /
8 GB or more for real builds, since the Android SDK and Gradle caches need both
CPU and disk.

## Secrets

Create these in the **Codespaces** secret store, not Actions — the two are
separate and Actions secrets are never injected into a codespace:

- Repository level: repo → Settings → Secrets and variables → **Codespaces**
- Account level: github.com/settings/codespaces, with this repository in
  *Repository access*

They are also declared under `secrets` in `devcontainer.json`, so Codespaces
prompts for them on "New with options" and stores the values in the user's own
settings. That keeps a public repository credential-free: secret values are only
injected when the creator has write access, and never into codespaces created
from forks.

| Name | Used for |
|---|---|
| `NETBIRD_SETUP_KEY` | NetBird setup key. **Must be reusable** — a one-off key enrolls exactly one machine. `NETBIRD_KEY` is accepted as an alias. |
| `OLLAMA_API_KEY` | Ollama Cloud key. `post-create.sh` exports it as `OLLAMA_API_KEY`, which is also the variable name models.dev declares for the `ollama-cloud` provider. `OLLAMA_API` is accepted as an alias. |

Values are copied into the container's environment when it is created or
restarted, so a new or rotated secret needs a stop/start (a rebuild also works).

## NetBird: one peer per machine, not per rebuild

Peer state lives in `/var/lib/netbird` (`default.json` holds the WireGuard
identity; `active_profile.json` and `state.json` sit beside it), and that path
is a named volume. So:

| Event | Result |
|---|---|
| Rebuild, stop, start | same peer reconnects; `netbird-up` exits early on `netbird status -C startup`; **no key spent** |
| New codespace | fresh VM, no volume → `netbird-up` enrolls with the setup key |
| Codespace deleted, or auto-deleted after 30 days idle | identity gone → next one enrolls again |

`netbird-up` distinguishes the two states with NetBird's own health probes:
`-C live` only proves the daemon answers, while `-C startup` proves management
and signal are connected. It waits briefly for an existing identity to
reconnect before falling back to `netbird up --setup-key`.

`--disable-dns` keeps NetBird away from `/etc/resolv.conf`, which would break the
container's own name resolution; adb targets are IPs anyway.

If you would rather not keep identity at all, create the key with the
**ephemeral peers** option (peers are removed after 10 minutes offline) and drop
the `/var/lib/netbird` mount: every start then registers a new peer, and the
dashboard stays clean.

Run it by hand with `sudo netbird-up`. Logs: `/var/log/netbird/client.log`.
Container setup log: `~/.local/state/devcontainer-setup.log`.

## Storage and compute

Codespaces bills compute per active hour and storage per GB-month of everything
in the codespace (image and postCreate installs included). Baking tools into an
image does not reduce storage, only rebuild time; prebuilds multiply storage per
region and per retained version. Re-downloading the Android SDK on a rebuild is
a ~306 MiB transfer inside billable compute, usually cheaper than holding an
extra copy around.

`post-create.sh` reports the SDK footprint after installing, so the number stays
visible instead of estimated.

## Deliberately not included: Alpine

NetBird's installer only handles `apt-get`, `dnf`, `yum` and `rpm-ostree`;
Alpine is musl, has no such package manager, and its busybox `nc` lacks what
`adb-connect.sh` needs. Every piece of this environment (Java feature, Android
cmdline-tools, `install_extras`' apt step) is Debian/Ubuntu territory. A
minimal Alpine variant would mean hand-rolling the NetBird binary install and
an Android SDK that still needs glibc.

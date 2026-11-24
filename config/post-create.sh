#!/usr/bin/env bash
# =============================================================================
# livetv - devcontainer bootstrap (postCreateCommand)
#
# What it does
#   tun ................. create /dev/net/tun if the image lacks it
#   netbird ............. install client, install the netbird-up helper
#   android sdk ......... cmdline-tools, platform-tools, platform 36, build-tools 36
#   opencode ............ CLI agent, installs to ~/.opencode/bin
#   jq .................. needed by adb-connect.sh and by hand
#
# Nothing here is committed to git: the SDK and the tools land in the container,
# so the repository stays a few KB and a rebuild only re-downloads ~300 MiB.
#
# Secrets: read from the Codespaces-injected env (NETBIRD_KEY / NETBIRD_SETUP_KEY,
# OLLAMA_API / OLLAMA_API_KEY), never written to disk or git. Both spellings of
# each are accepted so renaming a repo secret cannot silently break the setup.
#
# Re-entrant: every step is guarded, so re-running by hand is safe and a rebuild
# only downloads what is missing. Failures are reported, never fatal: a NetBird
# outage must not stop the Android SDK from installing.
# =============================================================================
set -uo pipefail   # deliberately no -e: optional tools must not abort the run

ANDROID_HOME_DIR=/usr/local/lib/android/sdk
ANDROID_PLATFORM=android-36
ANDROID_BUILD_TOOLS=36.0.0
CLT_FALLBACK_BUILD=15859902          # used only if the live lookup fails
STATE_DIR="$HOME/.local/state"
LOG="$STATE_DIR/devcontainer-setup.log"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$STATE_DIR"
: >>"$LOG"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*" | tee -a "$LOG"; }
warn() { printf '\033[1;33m warn\033[0m %s\n' "$*" | tee -a "$LOG"; }
have() { command -v "$1" >/dev/null 2>&1; }

# --- 1. tun device -----------------------------------------------------------
ensure_tun() {
  if [ -e /dev/net/tun ]; then
    say "tun: /dev/net/tun present"
    return 0
  fi
  say "tun: creating /dev/net/tun"
  sudo mkdir -p /dev/net
  sudo mknod /dev/net/tun c 10 200 2>>"$LOG" \
    || { warn "tun: mknod failed - NetBird will need netstack mode"; return 1; }
  sudo chmod 666 /dev/net/tun
}

# --- 2. netbird --------------------------------------------------------------
install_netbird() {
  if have netbird; then
    say "netbird: already installed ($(netbird version 2>/dev/null | head -1))"
  else
    say "netbird: installing"
    curl -fsSL https://pkgs.netbird.io/install.sh | sudo sh >>"$LOG" 2>&1 \
      || { warn "netbird: install failed (see $LOG)"; return 1; }
  fi
  install_helper
}

install_helper() {
  local src="$SCRIPT_DIR/netbird-up"
  if [ ! -f "$src" ]; then
    warn "netbird: helper missing at $src, postStart cannot join"
    return 1
  fi
  sudo install -m 0755 "$src" /usr/local/bin/netbird-up
  say "netbird: netbird-up helper ready"
}

# --- 3. android sdk (no Studio, no emulator) ---------------------------------
install_android() {
  local root="$ANDROID_HOME_DIR"

  if have sdkmanager; then
    say "android: sdkmanager already on PATH"
  else
    local build url
    build="$(curl -fsSL https://developer.android.com/studio 2>/dev/null \
      | grep -oE 'commandlinetools-linux-[0-9]+_latest\.zip' | head -1 \
      | grep -oE '[0-9]+')"
    build="${build:-$CLT_FALLBACK_BUILD}"
    url="https://dl.google.com/android/repository/commandlinetools-linux-${build}_latest.zip"

    say "android: downloading cmdline-tools ($build, ~170 MiB)"
    curl -fsSLo /tmp/clt.zip "$url" || { warn "android: download failed"; return 1; }

    sudo mkdir -p "$root/cmdline-tools"
    sudo unzip -q -o /tmp/clt.zip -d "$root/cmdline-tools" \
      || { warn "android: unzip failed"; return 1; }
    sudo rm -rf "$root/cmdline-tools/latest"
    sudo mv "$root/cmdline-tools/cmdline-tools" "$root/cmdline-tools/latest"
    sudo chown -R "$(id -un):" "$root"
    rm -f /tmp/clt.zip
  fi

  export ANDROID_HOME="$root" ANDROID_SDK_ROOT="$root"
  export PATH="$root/cmdline-tools/latest/bin:$root/platform-tools:$PATH"

  say "android: accepting licenses"
  yes 2>/dev/null | sdkmanager --licenses >>"$LOG" 2>&1 || true

  say "android: installing platform-tools, ${ANDROID_PLATFORM}, build-tools ${ANDROID_BUILD_TOOLS}"
  sdkmanager --install "platform-tools" "platforms;${ANDROID_PLATFORM}" \
    "build-tools;${ANDROID_BUILD_TOOLS}" >>"$LOG" 2>&1 \
    || { warn "android: sdkmanager failed (see $LOG)"; return 1; }

  # Only the three packages above are installed; emulator images and the NDK
  # would add several GB and are not needed to build.
  say "android: $(du -sh "$root" 2>/dev/null | cut -f1) on disk"
}

# --- 4. opencode -------------------------------------------------------------
install_opencode() {
  if have opencode; then
    say "opencode: already installed ($(opencode --version 2>/dev/null))"
    return 0
  fi
  say "opencode: installing"
  curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path >>"$LOG" 2>&1 \
    || { warn "opencode: install failed (see $LOG)"; return 1; }
}

# --- 5. terminal extras ------------------------------------------------------
install_extras() {
  local missing=()
  have jq     || missing+=(jq)
  have unzip  || missing+=(unzip)
  have bzip2  || missing+=(bzip2)
  have nc     || missing+=(netcat-openbsd)
  [ ${#missing[@]} -eq 0 ] && { say "extras: jq/unzip/bzip2/nc present"; return 0; }

  say "extras: installing ${missing[*]}"
  sudo apt-get update -qq >>"$LOG" 2>&1
  sudo apt-get install -y -qq "${missing[@]}" >>"$LOG" 2>&1 \
    || warn "extras: apt install failed (see $LOG)"
}

# --- 6. gradle cache volume --------------------------------------------------
fix_gradle_home() {
  sudo mkdir -p /opt/gradle-cache
  sudo chown -R "$(id -u):$(id -g)" /opt/gradle-cache
  say "gradle: GRADLE_USER_HOME=/opt/gradle-cache"
}

# --- 7. stable PATH for non-login shells -------------------------------------
write_env() {
  local f=/etc/profile.d/99-livetv-tools.sh

  say "env: writing $f"
  cat <<'PROFILE' | sudo tee "$f" >/dev/null
# Managed by config/post-create.sh (livetv).
# Variable NAMES only - values come from the Codespaces-injected env at shell
# start, so rotating a secret needs nothing more than a stop/start.
# Codespaces secret values can carry a trailing newline; strip it once here so
# the key is identical everywhere it is consumed.
# OLLAMA_API is the secret name; OLLAMA_API_KEY is the exported name opencode
# reads, so either can be the source depending on how the secret is defined.
_ollama_key="${OLLAMA_API:-${OLLAMA_API_KEY:-}}"
_ollama_key="${_ollama_key%"${_ollama_key##*[![:space:]]}"}"
export OLLAMA_API_KEY="$_ollama_key"
unset _ollama_key

export ANDROID_HOME=/usr/local/lib/android/sdk
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export GRADLE_USER_HOME=/opt/gradle-cache
export PATH="$PATH:$HOME/.opencode/bin:/usr/local/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools"
PROFILE

  if ! grep -q '99-livetv-tools' "$HOME/.bashrc" 2>/dev/null; then
    printf '\n# Managed by config/post-create.sh\n. /etc/profile.d/99-livetv-tools.sh\n' >>"$HOME/.bashrc"
  fi
}

link_bins() {
  local src
  for src in "$HOME/.opencode/bin/opencode"; do
    [ -x "$src" ] || continue
    sudo ln -sf "$src" "/usr/local/bin/$(basename "$src")"
  done
}

# --- run --------------------------------------------------------------------
say "livetv devcontainer setup starting (log: $LOG)"

ensure_tun
install_extras
fix_gradle_home

install_netbird & p1=$!
install_android & p2=$!
install_opencode & p3=$!

wait "$p1" || warn "netbird did not install cleanly"
wait "$p2" || warn "android sdk did not install cleanly"
wait "$p3" || warn "opencode did not install cleanly"

write_env
link_bins

date >"$STATE_DIR/devcontainer-setup.done"

say "versions"
printf '  %-10s %s\n' opencode "$(opencode --version 2>/dev/null || echo missing)" | tee -a "$LOG"
printf '  %-10s %s\n' netbird  "$(netbird version 2>/dev/null | head -1 || echo missing)" | tee -a "$LOG"
printf '  %-10s %s\n' adb      "$("$ANDROID_HOME_DIR/platform-tools/adb" version 2>/dev/null | head -1 || echo missing)" | tee -a "$LOG"
printf '  %-10s %s\n' java     "$(java -version 2>&1 | head -1)" | tee -a "$LOG"

say "done. new shell (or: source ~/.bashrc) to pick up PATH"
say "netbird joins on container start; run 'sudo netbird-up' now to join immediately"

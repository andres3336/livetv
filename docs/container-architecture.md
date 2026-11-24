# Container architecture

How this dev container is wired: the base image and SDK layout, the NetBird
overlay network, and the ADB-over-NetBird path used to reach a physical phone.
Written to be read cold — by a new contributor or by an LLM agent that has to
debug the environment without guessing.

Every claim below was verified in a live codespace on 2026-11-24 with NetBird
`0.83.2`, adb `37.0.3`, Android SDK platform `36`. Commands to re-verify are
given inline; if one disagrees with this document, trust the command.

Related: [`docs/devcontainers.md`](devcontainers.md) covers how to *create* the
environment (setup keys, secrets, machine size). This document covers how it
*works* once it exists.

---

## 1. The stack at a glance

```
  phone (SM-A356E, Android 17)
  ├─ adbd :<random 30000-49999>        ← wireless debugging, TLS + key auth
  └─ wt0  100.110.28.107/16
        │
        │  WireGuard, MTU 1280, often RELAYED
        │  (rels://streamline-us-nyc1-2.relay.netbird.io:443)
        ▼
  NetBird management / signal / relay (SaaS)
        ▲
        │
  codespace VM
  └─ docker container (this devcontainer, init:true, no systemd)
     ├─ netbird daemon (root)  ── wt0 100.110.20.255/16
     ├─ adb server (vscode)    ── :5037  → 127.0.0.1 transport
     ├─ Android SDK            ── /usr/local/lib/android/sdk
     └─ opencode               ── ~/.opencode/bin/opencode
```

Two independent channels matter, and they fail differently:

| Channel | Established by | Failure looks like |
|---|---|---|
| IP reachability | NetBird (`wt0` + relay/direct) | `timeout` on TCP connect |
| adb transport | adbd wireless debugging + paired key | `Connection refused` (port closed) or `unauthorized` |

That distinction is the single most useful debugging fact in this document: if
TCP gets **refused**, the tunnel works and the phone's adbd is not listening on
that port. Only a **timeout** implicates the network.

---

## 2. Layers

| Layer | What it is | Notes |
|---|---|---|
| Base image | `mcr.microsoft.com/devcontainers/base:ubuntu-24.04` | ~1 GB, glibc, apt |
| Runtime user | `vscode`, uid/gid 1000, member of `sdkman` | passwordless `sudo -n` |
| PID 1 | `docker-init` (`init: true`) | **no systemd, no journald** |
| JDK | 21 (`openjdk 21.0.13`), via devcontainer java feature | Gradle/Maven deliberately not installed |
| Android SDK | `/usr/local/lib/android/sdk` | platform-tools, `platforms;android-36`, `build-tools;36.0.0` |
| NetBird | `/usr/bin/netbird`, daemon as root | state in `/var/lib/netbird` named volume |
| opencode | `~/.opencode/bin/opencode`, symlinked to `/usr/local/bin` | config at repo root `opencode.json` |

Deliberately absent: systemd, Gradle, Maven, Android emulator images, NDK,
`python3`, `dig`/`host`/`nslookup`. Scripts in this repo stick to bash, `perl`
and `nc` because those are what the image guarantees.

---

## 3. Startup sequence

Two hooks, both idempotent.

`postCreateCommand` → `bash config/post-create.sh` (once per container build):

1. create `/dev/net/tun` if missing,
2. install apt extras (`jq`, `unzip`, `bzip2`, `netcat-openbsd`),
3. install NetBird, Android SDK, opencode **in parallel** (`&` + `wait`),
4. write `/etc/profile.d/99-livetv-tools.sh` (PATH, `ANDROID_HOME`, `OLLAMA_API_KEY`),
5. symlink `opencode` into `/usr/local/bin`.

Step 3 runs concurrently on purpose: each is network-bound and they do not share
state. A failure in one only warns — a NetBird outage must not block the SDK
install.

`postStartCommand` → `sudo env ... /usr/local/bin/netbird-up` (every start):

- starts the daemon detached (`setsid netbird service run`), because there is no
  systemd to supervise it,
- waits for `netbird status -C live` (daemon answers) then `-C startup`
  (management + signal connected),
- if an identity exists in `/var/lib/netbird`, exits early — **no setup key spent**,
- otherwise joins with `NETBIRD_KEY` / `NETBIRD_SETUP_KEY` and `--disable-dns`.

State that survives a rebuild: `/var/lib/netbird` (peer identity),
`/opt/gradle-cache`. State that does not: anything in `/tmp`, and the container
filesystem outside mounted volumes.

Logs: `/var/log/netbird/client.log`, `~/.local/state/devcontainer-setup.log`.

---

## 4. NetBird

### Identity and process model

The daemon runs as **root**, holding the WireGuard key in `/var/lib/netbird/default.json`.
`vscode` therefore cannot read full status:

```console
$ netbird status
Daemon status: Connected
...
Detailed status is unavailable: the connection belongs to another user.
```

Peer details (IPs, keys, relay, handshakes) need `sudo`:

```bash
sudo -n netbird status -d
sudo -n netbird status -d | sed -n '/sm-a356e.netbird.cloud:/,+3p'
```

`netbird status -C live` proves only that the daemon answers a status request;
`-C startup` proves management and signal are connected. `netbird-up` uses that
difference to decide "already enrolled, just reconnect" versus "join".

### Interfaces

```console
$ ip -4 addr show wt0
4: wt0: <POINTOPOINT,NOARP,UP,LOWER_UP> mtu 1280
    inet 100.110.20.255/16 scope global wt0
```

- `wt0` is a **kernel** WireGuard device, not userspace netstack. This works
  without `/dev/net/tun` (kernel WG is configured over netlink); on this machine
  `/dev/net/tun` does not exist and everything still works. The `mknod` step in
  `post-create.sh` is a no-op here, kept as a fallback for hosts where it matters.
- MTU 1280 leaves room for the outer encapsulation; assume small MTU when
  debugging payload stalls.
- `NET_ADMIN`, `NET_RAW`, `SYS_RESOURCE`, `MKNOD` are required in
  `devcontainer.json`; without `NET_ADMIN` the interface cannot be created.

### Relay vs direct

`sudo -n netbird status -d` reports `Connection type: Direct` or `Relayed` plus
the relay address. A codespace behind a cloud NAT commonly lands on a relay:

```
Connection type: Relayed
Relay server address: rels://streamline-us-nyc1-2.relay.netbird.io:443
```

Relayed means every packet crosses NetBird's relay: higher latency (tens of ms),
lower throughput. adb is fine over it; `screencap`/`install` are noticeably slower.
Status `Idle` with no handshake is normal until traffic flows — the first packet
triggers the handshake, so "Idle" is not "broken".

### DNS is intentionally off

`netbird-up` passes `--disable-dns`, so NetBird never touches `/etc/resolv.conf`.
Consequence: **peer hostnames do not resolve from a shell**.

| Query target | `sm-a356e.netbird.cloud` | `google.com` |
|---|---|---|
| `100.110.20.255:53` (NetBird's resolver) | `A 100.110.28.107`, TTL 300 | `rcode=5 REFUSED` |
| `127.0.0.53` (container stub) | `rcode=3 NXDOMAIN` | resolves normally |

NetBird's resolver serves only its own zone and refuses everything else, so it is
not a general-purpose nameserver. In practice:

- **use the peer IP** obtained from `sudo -n netbird status -d`,
- or add `100.110.28.107 sm-a356e.netbird.cloud` to `/etc/hosts` (container-local,
  lost on rebuild),
- or query `100.110.20.255` directly.

`getent hosts <peer>` fails and that is expected, not a NetBird outage.

---

## 5. Android toolchain

```
/usr/local/lib/android/sdk/
├── platform-tools/adb          # adb 37.0.3
├── build-tools/36.0.0/         # aapt2, d8, zipalign, apksigner, apkanalyzer...
├── platforms/android-36/android.jar
└── cmdline-tools/latest/bin/sdkmanager
```

No Gradle and no emulator. An APK is therefore assembled by hand — this is the
exact pipeline used to build the empty-activity app, and the one to copy for
throwaway test apps:

```bash
SDK=/usr/local/lib/android/sdk; BT=$SDK/build-tools/36.0.0; AJ=$SDK/platforms/android-36/android.jar

$BT/aapt2 link -o out/unsigned.apk -I $AJ \
  --manifest AndroidManifest.xml --java out/gen \
  --min-sdk-version 24 --target-sdk-version 36

javac -source 17 -target 17 -classpath $AJ -d out/classes $(find src out/gen -name '*.java')

$BT/d8 --lib $AJ --min-api 24 --output out/dex $(find out/classes -name '*.class')

(cd out/dex && zip -q ../unsigned.apk classes.dex)

$BT/zipalign -f -p 4 out/unsigned.apk out/aligned.apk
$BT/apksigner sign --ks /tmp/opencode/debug.keystore \
  --ks-pass pass:android --key-pass pass:android \
  --out out/app.apk out/aligned.apk
```

Notes:

- `aapt2 link` needs the manifest, `zipalign` must run **before** `apksigner`
  (signing then realigning invalidates the signature).
- A debug keystore can be generated with `keytool -genkeypair -keystore ...
  -alias androiddebugkey -storepass android -keypass android -dname "CN=Android Debug,O=Android,C=US"`.
- `targetSdkVersion 36` installs fine on an Android 17 (SDK 37) device.
- Use `@android:style/Theme.DeviceDefault.NoActionBar` in the manifest to avoid
  needing AppCompat or any resource files at all — a launcher activity can be
  built with zero `res/` entries.

---

## 6. ADB over NetBird (runbook)

Wireless debugging, not USB: the container has no USB passthrough, so the only
route is adbd listening on the phone's Wi-Fi/tailnet address.

### 6.1 Phone side

1. Settings → Developer options → **Wireless debugging** → on (phone must be on
   the same tailnet).
2. Either tap **Pair device with pairing code** (gives a *pairing* port + 6-digit
   code), or read the **IP address & port** line on the main screen (the
   *connect* port).

Those are two different ports. The pairing port closes immediately after a
successful pair; connecting to it afterwards gets `Connection refused`.

### 6.2 Pair once

```bash
adb pair 100.110.28.107:36225 178869
# Successfully paired to 100.110.28.107:36225 [guid=adb-RFCX30974TZ-BWZqMB]
```

Pairing persists the phone's authorization of `~/.android/adbkey`. Later
sessions need no code — only the current connect port.

### 6.3 Find the connect port

mDNS does not cross the tunnel (`adb mdns services` is empty even when the phone
is advertising), so the port must be read off the screen or discovered:

```bash
# probe the range Android draws wireless-debugging ports from
perl -e '
use IO::Socket::INET;
my $H="100.110.28.107"; my $W=250; my @k;
for my $w (1..$W){ my $p=fork(); if(!$p){
  for my $port (grep { $_ % $W == $w } 30000..49999){
    my $s=IO::Socket::INET->new(PeerAddr=>$H,PeerPort=>$port,Proto=>"tcp",Timeout=>1)
      and print "open $port\n"; } exit 0 } push @k,$p }
waitpid $_,0 for @k;'
```

More than one port can be open; adbd is the one that yields a usable transport:

```bash
adb connect 100.110.28.107:45119     # connected to ...
adb devices -l                       # <ip>:<port>  device
```

A port that connects but reports `offline` is not the adb data port — disconnect it
(`adb disconnect <ip>:<port>`) so `adb devices` stays clean.

### 6.4 Using the device

A network transport is not the default device, so pass `-s`:

```bash
adb -s 100.110.28.107:45119 shell getprop ro.product.model   # SM-A356E
adb -s 100.110.28.107:45119 install -r out/app.apk
adb -s 100.110.28.107:45119 shell am start -n com.example.empty/.MainActivity
adb -s 100.110.28.107:45119 exec-out screencap -p > screen.png
adb disconnect 100.110.28.107:45119
```

### 6.5 Failure taxonomy

| Symptom | Meaning | Fix |
|---|---|---|
| `failed to resolve host` | `--disable-dns`; peer names never resolve | use the IP from `sudo netbird status -d` |
| `Connection refused` | tunnel OK, nothing listening on that port | port changed; re-read it or scan |
| connect hangs / `timeout` | no route to peer | `sudo netbird status -d` — peer offline or not enrolled |
| connected then `offline` | wrong port (not adbd's) | disconnect, try the other open port |
| `unauthorized` | key not accepted | re-run `adb pair` with a fresh code |
| `adb devices` empty after reconnect | port churn after reboot/toggle | scan again; pairing itself survives |

The phone's port **changes** whenever wireless debugging is toggled or the phone
reboots, and the NetBird IP changes if the peer re-enrolls. Neither is a bug.

---

## 7. Traps worth knowing before debugging

- `netbird status` as `vscode` hides peer detail — always `sudo -n` when the
  answer matters.
- "Idle" peer status does not mean unreachable; traffic establishes the tunnel.
- Peer DNS names do not resolve. `NXDOMAIN` is expected.
- `adb mdns services` cannot see the phone across the tunnel.
- `adb install` here reports `Performing Incremental Install` — normal on modern
  adbd, not an error path.
- There is no systemd: never `systemctl`/`journalctl`; use the two log files.
- No `python3`, `dig`, `nslookup`, `wg`. Use `perl`, `nc`, `adb`, and
  `netbird status -d`.
- `POST`-installed tooling is not committed; a rebuild re-downloads ~300 MiB and
  the repo stays a few KB.
- `docs/devcontainers.md` mentions `config/adb-connect.sh` and a `jq` dependency
  for it, but that script does not exist in the repository — the runbook in
  section 6 is the actual procedure.

---

## 8. File map

| Path | Role |
|---|---|
| `.devcontainer/devcontainer.json` | image, caps, mounts, hooks, secrets |
| `config/post-create.sh` | one-time installs (SDK, NetBird, opencode, extras) |
| `config/netbird-up` | per-start daemon launch + enroll; installed as `/usr/local/bin/netbird-up` |
| `opencode.json` | opencode model config (root, no credentials) |
| `docs/devcontainers.md` | how to create/configure the environment |
| `docs/container-architecture.md` | this file: how the environment works internally |
| `/var/lib/netbird/` | peer identity (volume, survives rebuild) |
| `/usr/local/lib/android/sdk/` | SDK (container image layer, not git) |

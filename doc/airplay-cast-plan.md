# AirPlay 2 + Chromecast Receiver Plan

Status: **proposed**, not yet implemented. Targets `feat/airplay-shairport-sync` branch.

This document is the input to `/team-building` for adding alternative streaming
protocols to the ThirdReality voice/music speaker, alongside the existing
Sendspin client (which v1.1.8 introduced as a Snapcast replacement).

---

## 1. Goals

1. Speaker accepts AirPlay 2 streams as a destination, sample-accurate sync
   with HomePod/HomePod mini groups, full volume + metadata coupling.
2. Coexists cleanly with `sendspin-client` — neither breaks the other when both
   are configured/active. Single source of truth for volume.
3. Discoverable from HA without manual entry, same way the speaker now appears
   via `_esphomelib._tcp` and `_sendspin._tcp` (with the Custom Gateway mDNS
   Proxy list).
4. Fits the device's resource envelope (228 MB RAM, 4-core A53, ~78 MB free
   during sendspin playback).
5. Investigate whether the speaker can also be advertised/usable as a Google
   Cast endpoint. **Spoiler in §8: practically no, but the workable substitute
   is documented.**

Non-goals:
- AirPlay video — audio-only target.
- AirPlay 1 (legacy, unencrypted, single-device) — skipped, AirPlay 2 covers it.

## 2. Why AirPlay 2 (not 1)

| Aspect | AirPlay 1 | AirPlay 2 |
|---|---|---|
| Multi-room sync | No (one stream per device) | Yes (PTP-clocked groups) |
| Encryption | Optional, often plaintext | Always encrypted |
| Discovery TXT | `_raop._tcp` only | `_airplay._tcp` + `_raop._tcp` |
| iOS Control Center groups | No | Yes |
| Codec | ALAC only | ALAC, AAC, with adaptive |
| Stack | shairport-sync ≤3.x | **shairport-sync 4+ with `nqptp`** |

We pick AirPlay 2. shairport-sync 4 added the mode; 5.0.4 (2026-04-27) is the
current upstream and includes a recent PulseAudio bugfix worth pulling.

## 3. Architecture overview

```
                           Apple device (iOS / macOS / HomePod)
                                        │
                                  AirPlay 2 over TCP
                                        │
                ┌───────────────────────┴────────────────────────┐
                │                                                │
                ▼                                                ▼
       ┌──────────────────┐                             ┌──────────────────┐
       │ shairport-sync   │                             │  nqptp (daemon)  │
       │   :7000 (AirPlay)│                             │   :319 / :320    │
       │   :5000 (RAOP)   │                             │    PTP timing    │
       └────────┬─────────┘                             └────────┬─────────┘
                │ pcm s16le 44.1kHz                              │
                │                                                │ shared mem
                ▼                                                ▼
        ┌──────────────────┐                             (timing reference for
        │  PulseAudio sink │                              shairport-sync clock)
        │  alsa_output.    │
        │  hw_0_1 (48 kHz) │
        └────────┬─────────┘
                 ▲
                 │
        ┌────────┴─────────┐
        │ sendspin-client  │
        │  :8928 (already) │
        └──────────────────┘
```

shairport-sync writes to the same PA sink that sendspin-client and the voice
TTS layer (`mpv_player.py`) write to. PulseAudio sequences streams. We rely on
PA's default behavior; no explicit ducking is added in v1.

## 4. New buildroot package — `shairport-sync`

Location: `buildroot/package/thirdreality/shairport-sync/`

Files to add:
- `Config.in` — Kconfig stanza, depends on existing pulseaudio + avahi
- `shairport-sync.mk` — fetch + build rules
- `shairport-sync.service` — `/etc/avahi/services/` advertisement
- `shairport-sync.conf` — runtime config (PulseAudio backend, name template)
- `S52shairport-sync` — sysv init wrapper (alternative: integrate into S99)

Pin: `SHAIRPORT_SYNC_VERSION = 5.0.4` from `mikebrady/shairport-sync`.

Build options (cmake/configure):
```
--with-pa            # PulseAudio output (matches existing sink)
--with-avahi         # mDNS via avahi (already on device)
--with-ssl=openssl   # required for AirPlay 2 (SAP, encryption)
--with-airplay-2     # enable AP2 mode (the whole point)
--with-systemd=no    # busybox init, not systemd
--with-stdout=no     # no stdout backend
--with-pipe=no       # no named pipe
--with-metadata      # exposes metadata via dbus / MQTT (we'll wire later)
--with-mqtt=no       # not now
--with-dbus=session  # for metadata bridging if we want it later
```

Dependencies in the .mk:
- `pulseaudio` (already)
- `avahi` (already)
- `openssl` — needed for AP2; verify existing rootfs config includes it
- `popt` — shairport-sync configfile parser
- `libsoxr` — high-quality resampling, fixes 44.1k→48k path quality
- `libplist` — AP2 property lists
- `libsodium` — AP2 crypto
- `libgcrypt` + `libgpg-error` — legacy crypto where libsodium doesn't fit
- `nqptp` (companion package, see §5)

## 5. Companion package — `nqptp`

Location: `buildroot/package/thirdreality/nqptp/`

`nqptp` is a Precision Time Protocol helper that shairport-sync 4+ requires
for AirPlay 2 group sync. Without it, the speaker gets AP2 advertisement but
can't actually join HomePod groups.

Pin: `NQPTP_VERSION = 1.2.7` from `mikebrady/nqptp` (released 2026-05-05).

Service: must run as a separate daemon BEFORE shairport-sync starts.
Listens on UDP 319 + 320 and writes shared memory used by shairport-sync.

`S51nqptp` init script orders before `S52shairport-sync`.

## 6. Init integration

Two reasonable shapes — recommend **B** for consistency with existing patterns.

### Option A — standalone init scripts
- `/etc/init.d/S51nqptp` — start nqptp
- `/etc/init.d/S52shairport-sync` — start shairport-sync after nqptp

Pros: clean separation. Cons: doesn't share monitor_loop's process supervision,
no DISABLE_* override hooks.

### Option B (recommended) — extend `S99ha-speaker` monitor_loop
Add to the existing supervisor in `S99ha-speaker`:

```bash
DISABLE_AIRPLAY=/tmp/ha_disable_airplay
NQPTP=/usr/bin/nqptp
SHAIRPORT_SYNC=/usr/bin/shairport-sync

start_airplay() {
    pidof shairport-sync > /dev/null 2>&1 && return 0

    rm -f "$DISABLE_AIRPLAY"
    pidof nqptp > /dev/null 2>&1 || \
        start-stop-daemon --start --quiet --background --name nqptp --exec "$NQPTP"

    # Wait a beat for nqptp to create its shared memory before shairport-sync
    # tries to mmap it.
    sleep 1

    local spk_name
    spk_name=$(jq -r '.device.name // "3RSPK Speaker"' "$DEVICE_CONF")
    start-stop-daemon --start --quiet --background --name shairport-sync \
        --exec "$SHAIRPORT_SYNC" -- -c /etc/shairport-sync.conf -a "$spk_name"
}

stop_airplay() {
    touch "$DISABLE_AIRPLAY"
    start-stop-daemon --stop --quiet --retry=TERM/30/KILL/5 --name shairport-sync
    start-stop-daemon --stop --quiet --retry=TERM/30/KILL/5 --name nqptp
}
```

Plus the corresponding monitor_loop check, service_cmd dispatch, and
`stop()` cleanup. This mirrors how netmonitor / voice-assistant /
sendspin-client are managed.

## 7. mDNS — `/etc/avahi/services/shairport-sync.service`

shairport-sync 4+ is _supposed_ to publish its own AP2 records (via avahi at
runtime), so a static .service file might double-publish. Verify behavior in
testing. If the dynamic publish works, **omit** the static file. Otherwise
ship the file as a fallback.

For reference, the records AirPlay 2 needs:
- `_airplay._tcp` port 7000 — primary AP2 service
- `_raop._tcp` port 5000 — RAOP (legacy fallback inside AP2)

Both must include TXT records identifying device class, supported audio
formats, and encryption capabilities. shairport-sync builds these correctly;
we should not hand-edit them.

## 8. Chromecast — research findings

User asked: **can the speaker also advertise itself as a Chromecast?**

**Original short answer was: "not realistically — no FOSS Cast receiver
exists." That was wrong on the literal claim and is corrected below.** A
project named **shanocast** (rgerganov/shanocast, last meaningful commit
2026-03) does implement a working Chromecast receiver on Linux by patching
Google's Openscreen library. The walls are different from what I first wrote.

### 8.1 What shanocast actually delivers (and doesn't)

- **Scope**: Chrome browser tab cast and full-desktop cast. The README and
  demo show "mirror a Chrome tab or the entire desktop." Audio-app casting
  (Spotify Connect, YouTube Music, Apple Music in-app cast) is **not** in the
  documented or tested feature set.
- **Build dependencies** (per `cast_receiver.nix`): `gn`, `ninja`, `python3`,
  `pkg-config`, `ffmpeg`, **`SDL2`**. SDL2's presence indicates the binary
  expects a display surface — this is a tab/desktop mirror receiver, not a
  Cast Audio receiver.
- **Build system**: GN + ninja, Chromium-style. Buildroot has no native
  pattern for Chromium subprojects; recipes for upstream `openscreen` do not
  exist in our buildroot tree.
- **Authentication mechanism**: ships extracted Google "Eureka Gen1 ICA"
  intermediate certificate + 45 KB of precomputed RSA signatures (covering
  2023-08-15 through 2027-12-21) that exploit a `enforce_nonce_checking =
  false` flag in Chrome's Openscreen client. Embedded directly in the patch
  as C arrays.
- **Hard expiry**: signature window ends 2027-12-21. After that, the receiver
  stops authenticating until the exploit is re-derived or Google fixes the
  Chrome flag (which, when fixed, breaks shanocast permanently).
- **License/IP**: the project ships extracted Google PKI material. The author
  named the project after Bulgarian slang for "shady/illegal" and warns "I
  don't think this hack will work for long." Distribution risk on a
  commercial/forkable firmware image is not zero.

### 8.2 mDNS impersonation alone still breaks at first connect

Without shanocast's specific signature-replay mechanism, a `_googlecast._tcp`
advertisement still fails at first connect:
1. TLS handshake using Google PKI; speaker has no cert → fail
2. CASTV2 channel auth using deviceauth proto with nonce → fail
3. Even if bypassed, the receiver app dispatch layer expects the Cast SDK
   runtime to render apps

So the question of Cast support reduces to: are we shipping shanocast (with
all its caveats), are we using MA's bridges, or are we substituting a
different protocol (DLNA)?

### 8.3 What MA already provides (the workable answer)

Music Assistant's Sendspin provider includes `BridgePlayerRole`
(`music_assistant/providers/sendspin/bridge_role.py`) — explicitly designed
to bridge Sendspin players into AirPlay/Cast/etc. groups **on the server side**.

Quote from the source:
> "Reusable bridge player role for external player bridges. Provides a
> BridgePlayerRole that receives audio from Sendspin's PushStream and forwards
> it to an external player via callbacks. This role can be used by any bridge
> implementation (AirPlay, etc.) to integrate external players with Sendspin's
> synchronization and timing."

In practice: if the user has any actual Cast device on the network (Nest Mini,
Cast-capable TV, etc. — and we already saw `Google-Nest-Mini-…` and
`HT-A5000-…` on this network's mDNS), MA can group it with the
ThirdReality speaker via Sendspin bridges, achieving cross-protocol sync.

### 8.4 Two possible substitutes if Cast-shaped UX matters

Neither is Cast, but covers the "send audio to speaker from random app" need:

**Option a — DLNA / UPnP MediaRenderer**: Add `pulseaudio-dlna` (or
`gerbera`) as a buildroot package. iOS apps lacking AirPlay 2 still don't
help, but Android, BubbleUPnP, VLC, and many media servers can target it.
Footprint similar to shairport-sync. Could be a v2 deliverable.

**Option b — Snapcast (revert/parallel)**: The pre-1.1.8 stack the user just
moved off of. Not recommended for re-adding.

### 8.5 Recommendation (updated)

The right matrix to test, rather than picking one path, is **five separate
build branches** so we can compare on hardware:

| # | Branch | Contents |
|---|---|---|
| 1 | `linux-voice-assistant` | Sendspin fixes only (already shipped) |
| 2 | `feat/airplay-shairport-sync` | Sendspin fixes + AirPlay 2 (this plan) |
| 3 | `feat/chromecast-shanocast` | Sendspin fixes + shanocast (Chrome tab cast) |
| 4 | `feat/dlna-pulseaudio` | Sendspin fixes + DLNA receiver |
| 5 | `feat/everything` | All of the above |

shanocast (#3, #5) ships at known risk: 2027 expiry, Chromium build system,
embedded extracted PKI, scope limited to Chrome browser cast. DLNA (#4, #5)
covers the "send audio from a non-Apple app to the speaker" need for clients
like BubbleUPnP, VLC, and many Android media apps — different protocol but
similar end-user effect, and it doesn't carry shanocast's caveats.

Per-branch implementation plans for #3 and #4 live in `doc/cast-shanocast-plan.md`
and `doc/dlna-plan.md` respectively. This plan (#2) stays focused on AirPlay 2.

## 9. Volume + state coupling

Existing state file: `/data/conf/sound.json`
```json
{ "volume": 80, "mic_gain": 30, "mic_mute": 1, ... }
```

`sendspin-client` reads/writes the `volume` field on every change
(`sendspin-client.cpp:33-77`).

shairport-sync also fires volume callbacks. Two options:

1. **Configure shairport-sync's `general.volume_control_profile = "flat"`**
   and have it write to the PA sink directly via `pactl set-sink-volume`,
   matching what sendspin does, AND tail the PA volume → write back to
   `sound.json`. This keeps a single source of truth.
2. **Delegate volume entirely to shairport-sync's PulseAudio backend** (don't
   persist), which means AirPlay volume changes don't survive a reboot.

Recommend (1). Implementation: add a tiny `shairport-volume-bridge.sh` that
listens on shairport-sync's metadata pipe for volume events and updates
`sound.json` (using the same `persist_volume` pattern as
`sendspin-client.cpp`). Or shorter: just call `pactl set-sink-volume` and let
the existing `sync_local_volume` tick in sendspin-client pick it up.

## 10. Implementation phases

Phase 1 — buildroot packaging (independent):
- (P1.A) `nqptp` package
- (P1.B) `shairport-sync` package with AP2 build flags and PA backend
- Defconfig: `BR2_PACKAGE_NQPTP=y`, `BR2_PACKAGE_SHAIRPORT_SYNC=y`

Phase 2 — runtime integration (depends on Phase 1):
- (P2.A) Init wiring in `S99ha-speaker` (Option B from §6)
- (P2.B) `/etc/shairport-sync.conf` runtime config tuned for this speaker
- (P2.C) Volume bridge to `sound.json` (per §9)

Phase 3 — verification (depends on Phase 2):
- (P3.A) `_airplay._tcp` and `_raop._tcp` visible from a Mac on same SSID
- (P3.B) Audio plays from iOS Control Center > AirPlay
- (P3.C) HomePod group sync (latency < 50 ms vs HomePod)
- (P3.D) Concurrent sendspin + AirPlay attempt — document expected behavior
- (P3.E) Headroom regression — RAM/CPU vs current baseline

Phase 4 — docs (independent of 3):
- README section under `## Multi-Room Music` for AirPlay coupling
- Link to this plan; remove ambiguity around Cast support (point to bridges)

Phases map to `/team-building` agents:
- Agent A: buildroot packager (Phase 1)
- Agent B: init/runtime integrator (Phase 2)
- Agent C: validation + docs (Phases 3-4)

Phase 1 is fully parallelizable across A's worktree.
Phase 2 must wait on Phase 1's commits to land on the branch.
Phase 3 must wait on Phase 2.

## 11. Validation criteria (lead checks before merge)

- [ ] Build: `./go trspk` succeeds with new packages
- [ ] Image: shairport-sync + nqptp present in `/usr/bin/`
- [ ] Boot: both daemons running after monitor_loop converges, no crash loop
- [ ] mDNS: `avahi-browse -art _airplay._tcp` from any LAN host shows speaker
- [ ] AirPlay 2: AirPlay icon in iOS Control Center lists `3RSPK-…`
- [ ] Audio: stream music from iOS, audible on speaker
- [ ] Group: pair with a HomePod, verify sync < 50 ms (visual A/B)
- [ ] Sendspin coexistence: switch from MA to AirPlay and back, no crash
- [ ] Volume: change from iOS, observe `pactl list sinks` and `sound.json`
- [ ] Memory: RSS budget — shairport-sync + nqptp combined under 25 MB
- [ ] CPU: idle CPU stays > 80% with both stacks idle
- [ ] Reboot: services come back automatically

## 12. Risks and open questions

- **R1: PulseAudio sink contention.** sendspin and shairport-sync both write
  to `@DEFAULT_SINK@`. Concurrent playback will sequence, not mix — need to
  confirm UX isn't terrible. Mitigation: document that simultaneous use is
  unsupported; or add `module-combine-sink` / per-source virtual sinks later.
- **R2: nqptp wants ports 319/320.** Verify nothing else binds them; confirm
  the kernel allows non-root processes (busybox start-stop-daemon as root is
  fine, but worth confirming the binary doesn't drop perms before bind).
- **R3: SSL/crypto rootfs size.** AP2 requires openssl + libsodium + libplist
  + libsoxr + libgcrypt. Could push the rootfs over flash budget. We have
  ~72 MB free on /rom — should fit but verify after image build.
- **R4: 44.1k → 48k resampling quality.** AP2 streams arrive at 44.1k;
  PulseAudio resamples to the 48k hardware sink with `ffmpeg` resampler
  (per current `pactl list sink-inputs`). With `libsoxr` available
  shairport-sync may be able to do high-quality resampling itself; verify
  audible quality.
- **R5: Multiple identities on the same device.** Speaker will advertise as
  ESPHome (`_esphomelib._tcp`), Sendspin client (`_sendspin._tcp`), and
  AirPlay 2 (`_airplay._tcp`). UniFi mDNS Custom proxy list needs all three
  added — already done for first two; add `_airplay._tcp` and `_raop._tcp`
  on the gateway.
- **R6: shairport-sync 4+ runtime mDNS publish.** Verify whether shairport
  publishes via avahi-daemon directly (most likely on this rootfs) or its
  own mDNS responder. Latter could conflict with avahi.
- **Q1**: which device-name field does AirPlay show? Probably the one we pass
  with `-a`. Coordinate with sendspin's `friendly_name` so users see the same
  name in iOS AirPlay picker and Music Assistant.
- **Q2**: does the existing `device.json` schema need a `bluetooth_address`
  for AP2 (some clients key off it)? Verify whether shairport-sync reads MAC
  from /sys or expects config.

---

Source-of-truth pointers:
- shairport-sync: https://github.com/mikebrady/shairport-sync (5.0.4)
- nqptp: https://github.com/mikebrady/nqptp (1.2.7)
- AirPlay 2 protocol info: https://openairplay.github.io/airplay-spec/
- Sendspin protocol: https://github.com/Sendspin/spec
- MA bridge role: `music_assistant/providers/sendspin/bridge_role.py`

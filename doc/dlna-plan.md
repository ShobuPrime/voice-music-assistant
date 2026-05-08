# DLNA / UPnP Receiver Plan (gmrender-resurrect)

Status: **proposed**, not yet implemented. Targets `feat/dlna-gmediarender`.

This document is the input to `/team-building` for adding a DLNA / UPnP
MediaRenderer to the ThirdReality voice/music speaker, on top of the Sendspin
fixes already in `linux-voice-assistant`. It is the simplest of the four
add-on protocols because the buildroot package already exists upstream.

---

## 1. Goals

1. Speaker accepts UPnP/DLNA "Push" audio streams from Android apps
   (BubbleUPnP, VLC, Hi-Fi Cast), Linux apps (`gnome-music`, `Strawberry`),
   and most home-theater receivers acting as DLNA controllers.
2. Coexists with `sendspin-client` and (on the `feat/everything` branch) with
   `shairport-sync` — single audio sink, unified volume.
3. Discoverable via SSDP (the UPnP discovery protocol) — automatic on the
   same L2 segment, but on cross-VLAN setups requires an SSDP/UPnP relay
   (UniFi's mDNS proxy does not handle SSDP — different protocol).
4. Negligible footprint impact (gmrender-resurrect itself is small; gstreamer
   is the heavyweight dep).

Non-goals:
- Acting as a UPnP MediaServer (browsing local content). gmrender-resurrect
  is renderer-only; serving content is `gerbera`/`minidlna`'s job.
- Casting from iOS apps. Most iOS apps don't speak DLNA — that's AirPlay's
  job (separate branch).

## 2. Why gmrender-resurrect

| Tool | Verdict | Notes |
|---|---|---|
| **gmrender-resurrect** ✅ | recommended | Already in upstream buildroot (`buildroot/package/gmrender-resurrect/`); v0.1 pinned. Latest is v0.3.1 (2026-02-13). Active project (925 stars, hzeller maintained). C, gstreamer-backed, designed for embedded. |
| `pulseaudio-dlna` | ❌ | Despite the name, it's a *sender*: creates PA sinks for remote DLNA renderers. Wrong direction. |
| `rygel` | overkill | GNOME's full UPnP A/V stack with renderer + server + media server discovery. ~10x the dep footprint. |
| `gerbera` (formerly mediatomb) | ❌ | Server-only (browse + serve content). Not a renderer. |
| `minidlna` | ❌ | Server-only. |

## 3. Architecture overview

```
                       Android phone / VLC / DLNA Controller
                                        │
                              UPnP/DLNA over HTTP
                              (SSDP discovery on
                                 239.255.255.250:1900)
                                        │
                                        ▼
                          ┌─────────────────────────┐
                          │   gmrender-resurrect    │
                          │      (port 49494)       │
                          │  - SSDP responder       │
                          │  - UPnP control point   │
                          │  - HTTP media URL fetch │
                          └────────────┬────────────┘
                                       │ gstreamer pipeline
                                       │   uri → decode → pulsesink
                                       ▼
                           ┌────────────────────┐
                           │   PulseAudio sink  │
                           │  alsa_output.hw_0_1│
                           └────────┬───────────┘
                                    ▲
                  ┌─────────────────┼─────────────────┐
                  │                                   │
       ┌──────────────────┐                  ┌──────────────────┐
       │ sendspin-client  │                  │  shairport-sync  │
       │   :8928 (cur.)   │                  │ :7000 (everything│
       │                  │                  │  branch only)    │
       └──────────────────┘                  └──────────────────┘
```

Like the existing protocols, gmrender writes to PulseAudio's default sink.
PA sequences streams.

## 4. Buildroot wiring (no new package needed)

The package already exists at `buildroot/package/gmrender-resurrect/`. Only
defconfig changes required:

```
BR2_PACKAGE_GMRENDER_RESURRECT=y
BR2_PACKAGE_GSTREAMER1=y                     # implicit select, but be explicit
BR2_PACKAGE_GST1_PLUGINS_BASE=y              # implicit select
BR2_PACKAGE_GST1_PLUGINS_GOOD=y              # for pulsesink
BR2_PACKAGE_GST1_PLUGINS_GOOD_PULSE=y        # the pulsesink plugin specifically
BR2_PACKAGE_GST1_PLUGINS_GOOD_AUDIO=y        # rgvolume, etc.
BR2_PACKAGE_GST1_PLUGINS_GOOD_SOUP=y         # HTTP source for streaming URIs
BR2_PACKAGE_GST1_PLUGINS_GOOD_FLAC=y         # FLAC decode (DLNA controllers
                                             #  push FLAC for lossless)
BR2_PACKAGE_GST1_PLUGINS_BAD=y               # may be needed by some codecs
BR2_PACKAGE_GST1_PLUGINS_UGLY=y              # MP3 decoder
BR2_PACKAGE_GST1_LIBAV=y                     # ffmpeg-backed plugin (broad codec)
BR2_PACKAGE_LIBUPNP=y                        # implicit select
```

The implicit `select`s in gmrender-resurrect's Config.in only pull in the
hard requirements; codec plugins must be explicit.

### Optional: bump to v0.3.1

The upstream buildroot package pins v0.1 (much older). To use 0.3.1:

Option a — leave it at v0.1 (works, less code in our fork)
Option b — override locally by adding our own .mk under `package/thirdreality/gmrender-resurrect/` with the version bumped, and remove the upstream Config.in source line (same pattern we used for shairport-sync). More commits, more maintenance.

**Recommend option a** for v1 of this branch. Bumping is a follow-up PR upstream-able to buildroot itself.

## 5. Init integration (S99ha-speaker)

Mirroring the airplay/sendspin pattern in `S99ha-speaker`. New constants and
functions:

```sh
DISABLE_DLNA=/tmp/ha_disable_dlna
GMRENDER_RESURRECT=/usr/bin/gmediarender

start_dlna() {
    pidof gmediarender > /dev/null 2>&1 && return 0

    rm -f "$DISABLE_DLNA"
    local spk_name
    spk_name=$(jq -r '.device.name // "3RSPK Speaker"' "$DEVICE_CONF")

    # gmediarender args:
    #   -f <name>            : friendly name shown in DLNA controllers
    #   -u <uuid>            : stable UUID per device (required for client
    #                          re-connection without rediscovery)
    #   --gstout-audiosink   : gstreamer audiosink (pulsesink for our setup)
    #   --logfile /dev/null  : avoid filling flash with logs
    local mac
    mac=$(jq -r '.device.macAddress' "$DEVICE_CONF" | tr -d ':' | tr 'A-Z' 'a-z')
    local uuid="3rspk-dlna-${mac}"

    start-stop-daemon --start --quiet --background --name gmediarender \
        --exec "$GMRENDER_RESURRECT" -- \
        -f "$spk_name" -u "$uuid" \
        --gstout-audiosink=pulsesink \
        --logfile=/dev/null
}

stop_dlna() {
    touch "$DISABLE_DLNA"
    start-stop-daemon --stop --quiet --retry=TERM/30/KILL/5 --name gmediarender
}
```

Plus the corresponding monitor_loop entry, service_cmd dispatch case, and
stop() teardown — same shape as `start_airplay`/`stop_airplay` from the
AirPlay branch.

DLNA does NOT need to wait for NTP (no PTP-style timing), so it should NOT
be added to the boot-time `touch DISABLE_*` list.

## 6. mDNS / SSDP

- gmrender-resurrect speaks SSDP, **not mDNS**. SSDP uses multicast group
  `239.255.255.250:1900`.
- UniFi's mDNS Proxy does NOT relay SSDP. Cross-VLAN UPnP discovery requires
  either:
  - HA + speaker on the same VLAN (cleanest)
  - A dedicated SSDP/UPnP relay (e.g., the `igmpproxy` UniFi feature, or a
    `ssdp-relay` daemon on a dual-homed host)
- No avahi service file needed. gmrender publishes its own SSDP descriptors
  on its HTTP port.

This is documented in the README so users with VLAN-segmented networks know
what to configure on the gateway.

## 7. Volume coupling

Same as AirPlay: gmrender-resurrect implements UPnP RenderingControl, which
maps to the gstreamer pipeline volume. We configure it to write through to
PulseAudio's default sink so volume stays unified with sendspin and (where
applicable) AirPlay.

Defaults:
- `pulsesink` honors per-app volume; UPnP volume changes in gmrender map to
  the gstreamer pipeline's volume property. To unify with the system sink
  (and the existing `pactl set-sink-volume` flow used by sendspin), we'd
  add a small wrapper or a custom audiosink.
- For v1: leave per-stream volume as-is (gstreamer-side). Document the
  divergence; revisit in a follow-up if it's annoying. Hardware buttons
  still control the master sink volume, so this is mostly fine.

## 8. Implementation phases

Phase 1 — defconfig (independent):
- (P1.A) Add BR2_PACKAGE_GMRENDER_RESURRECT=y and gstreamer plugin flags
- (P1.B) Verify gstreamer1 + plugin deps don't blow up the rootfs size budget

Phase 2 — runtime integration:
- (P2.A) S99ha-speaker: start_dlna / stop_dlna / monitor_loop entry / service_cmd
- (P2.B) Confirm gmrender-resurrect command-line flags against v0.1 (the version we'll ship)

Phase 3 — docs:
- (P3.A) README subsection "Work with DLNA / UPnP" alongside HomePod/Sonos/AirPlay

## 9. Validation criteria

- [ ] Build: `./go trspk` succeeds with new flags
- [ ] Image: `gmediarender` present in `/usr/bin/`
- [ ] Boot: monitor_loop starts gmediarender; visible in `pidof gmediarender`
- [ ] SSDP: `gssdp-discover -i wlan0` from a Linux host on the same VLAN sees the speaker as `urn:schemas-upnp-org:device:MediaRenderer:1`
- [ ] Stream: `BubbleUPnP` (Android) or `vlc cvlc --intf dummy --sout '#chromecast{...}'` can target the speaker; audio plays
- [ ] Volume: UPnP RenderingControl SetVolume changes audible output level
- [ ] Concurrency: switch from sendspin to DLNA; sendspin reclaims sink afterward (confirm no PulseAudio sink stuck-busy state)
- [ ] Memory: gmediarender RSS < 30 MB; speaker idle CPU > 75%

## 10. Risks and open questions

- **R1: gstreamer1 footprint**. gst1 + plugins-good + plugins-bad + plugins-ugly + libav can balloon the rootfs by tens of MB. May need to trim plugin selection. Validate after first build.
- **R2: pulsesink behavior under sendspin contention**. When sendspin holds the sink and DLNA tries to write, gstreamer's pulsesink will queue/wait. UX might be "DLNA buffers indefinitely" rather than fail-fast. Test.
- **R3: SSDP cross-VLAN**. Without an SSDP relay on the gateway, DLNA won't be cross-VLAN. We can document this; we can't fix it from the speaker side.
- **R4: gmrender v0.1 vs v0.3.1**. v0.1 is from ~2014. May lack codec coverage (Opus added later). Acceptable for first cut; bump if reports come in.
- **Q1**: should we ship a custom UUID per device, or let gmrender generate one? Custom (MAC-derived) is more stable for client bookmarks; document the choice in the .mk install hook.

---

Source-of-truth pointers:
- gmrender-resurrect: https://github.com/hzeller/gmrender-resurrect (v0.3.1 latest, v0.1 in our buildroot)
- DLNA UPnP A/V spec: https://upnp.org/specs/av/UPnP-av-MediaRenderer-v1-Device.pdf
- SSDP: RFC draft `draft-cai-ssdp-v1-03`
- This plan's parent (multi-protocol overview): `doc/airplay-cast-plan.md` §8.5

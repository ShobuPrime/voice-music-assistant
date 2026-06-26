# CLAUDE.md — ShobuPrime/voice-music-assistant

A **fork** of [`thirdreality/voice-music-assistant`](https://github.com/thirdreality/voice-music-assistant)
(ThirdReality A113/Cortex-A53 voice+music speaker firmware, Buildroot-based).
Goal: carry a set of **custom features** on top of upstream while staying at
**full parity** with each official release. When upstream cuts a new tag, we
merge it in, re-verify parity, and rebuild.

> **Architecture note (v1.2.0+):** upstream replaced the Python voice
> assistant with a native C++ one — package `linux-voice-assistant-cpp`
> (WebRTC AEC3, music-reactive LED, tap-key control, Apache-2.0). The old
> Python `linux-voice-assistant` package still exists in-tree but is
> deselected from defconfig; do not re-enable it. S99ha-speaker now launches
> `/usr/bin/linux-voice-assistant-cpp --name <n> --port 6053`.

## Remotes

- `origin` → `git@github.com:ShobuPrime/voice-music-assistant.git` (our fork)
- `upstream` → `https://github.com/thirdreality/voice-music-assistant.git`
  (add once: `git remote add upstream …`; releases are tags `vX.Y.Z`)

## Branch topology

| Branch | Contents |
|---|---|
| `linux-voice-assistant` | **baseline** — upstream tag + shared custom commits. The branch every feature branch merges from; the main branch for PRs. |
| `feat/dlna-gmediarender` | baseline + DLNA (gmrender-resurrect + gstreamer) |
| `feat/airplay-shairport-sync` | baseline + AirPlay 2 (shairport-sync 5.0.4 + nqptp 1.2.7) |
| `feat/everything` | baseline + DLNA + AirPlay 2 (the union; the flagship image) |
| `feat/wake-word-hey-nimbus` | **deprecated** — old tangled integration branch, out of scope; do not build/update unless asked. |

## Custom features (our deltas vs upstream)

Everything below is what `git diff <tag>..linux-voice-assistant` (plus the
feature-branch extras) should show — nothing more. If a parity diff shows
anything else, investigate before building.

**On `linux-voice-assistant` baseline (so on every active branch):**
- **Wake words** — `buildroot/package/thirdreality/linux-voice-assistant-cpp/wakewords/openwakeword/{hey_nimbus,nimbus}.{tflite,json}` (openWakeWord type, author "Anthony Dardano"). **Since v1.2.0** these live in the C++ package (before, the Python pkg's `linux-voice-assistant/src/wakewords/`). The `.mk`'s `INSTALL_WAKEWORDS` post-install hook copies every `wakewords/{microwakeword,openwakeword}/*.{tflite,json}` to `/usr/share/thirdreality/wakewords/…` on the device. **v1.2.0 manifest schema** (the C++ loader rejects anything else): `{"type":"open","wake_word":…,"model":"X.tflite","trained_languages":["en"],"open":{"probability_cutoff":0.5,"sliding_window_size":5}}` — NOT the old Python `type:"openWakeWord"` form. The `author` field is ignored by the loader (kept for attribution). The live `nimbus.tflite` is the user's; treat its bytes as authoritative — do not regenerate. Like upstream's other openWakeWord models (alexa, hey_jarvis), they're installed but only **active** when the assistant runs `--wakeword-type open` — S99ha-speaker is left at upstream default per the rule below, so activation is a runtime/HA concern.
- **Kernel MODVERSIONS fix** — `buildroot/board/thirdreality/trspk/kernel-fix.config` + a `BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES=…` line in `buildroot/configs/3reality_trspk_defconfig`. Needed because the cross-toolchain (gcc-arm-10.2, binutils 2.35) + relocatable kernel 5.4 + `__crc_*` CRC symbols make the vmlinux link fail; disabling `CONFIG_MODVERSIONS` unblocks it. Keep it regardless of build env.
- **sendspin `software_version` from env** — `…/sendspin-client/sendspin-client.cpp` reads the `firmware_version` environ var instead of the hardcoded `"1.0.0"`.
- **avahi surgical rename** — `…/tr-proj-ha-speaker/script/S99ha-speaker` uses `avahi-set-host-name` instead of bouncing `S50avahi-daemon` (avoids an mDNS blackout that hid `_esphomelib._tcp` from HA).
- **Daemon stdio → /dev/null** — in `S99ha-speaker`, the sendspin `start-stop-daemon` line gets `> /dev/null 2>&1` (limited tmpfs, long uptime). Feature branches add the same to their daemons (gmediarender, nqptp, shairport-sync). **Only the new-feature daemons** — do not touch upstream's voice-assistant/netmonitor/monitor_loop invocations.

**On `feat/airplay-shairport-sync` + `feat/everything`:**
- AirPlay 2 packages `buildroot/package/thirdreality/{shairport-sync,nqptp}/`, defconfig enables, S99ha-speaker `start_airplay` block, and removal of the unused vanilla `buildroot/package/shairport-sync/`.
- **plistutil build dep** — `buildroot/package/libplist/libplist.mk` registers a host variant (`$(eval $(host-autotools-package))` + `HOST_LIBPLIST_CONF_OPTS = --without-cython`) and `shairport-sync.mk` depends on `host-libplist`. shairport-sync's configure needs the `plistutil` tool for AirPlay 2; the official Dockerfile doesn't ship it (upstream has no AirPlay), so we build it via Buildroot to keep the Dockerfile untouched.

**On `feat/dlna-gmediarender` + `feat/everything`:**
- DLNA: gmrender-resurrect + gstreamer enablement, defconfig, S99ha-speaker `start_dlna` block (gmediarender already has `--logfile=/dev/null`; we also add stdio redirect).

## Building

Use the **official** Docker flow (adopted at v1.1.9): no host deps beyond Docker
+ initialized toolchain submodules (`git submodule update --init`; the
`sources/toolchain/*` dirs must exist — the official `Dockerfile` symlinks them).

- `./go --docker trspk [version]` — build (official)
- `./go --docker-shell` — interactive container
- `./go --docker trspk rebuild <pkg>` — rebuild one package

**Prefer the wrapper `./docker-go.sh`** (untracked local helper): it delegates to
`./go --docker` but auto-derives a branch-aware version
`YYYY.MM.DD_<branch>_<shorthash>` so images across branches don't collide
(official default is date-only and would overwrite). `./docker-go.sh trspk`,
`./docker-go.sh shell`, `./docker-go.sh trspk rebuild <pkg>`.

- Output: `image/trspk_<version>.{img,swu}`.
- **Full clean rebuild** = `rm -rf output/` then build (~2h/branch). The
  `buildroot/dl/` download cache survives and should not be wiped.
- Keep the upstream `Dockerfile` **byte-identical to upstream**. If a custom
  feature needs a build tool, add it via Buildroot (see plistutil), never by
  editing the official Dockerfile.

## Keeping in sync with a new upstream release (the playbook)

**Always check whether a newer upstream release exists — proactively, at the
start of any maintenance/build work on this repo, not only when told one
dropped.** Run `git fetch upstream --tags` and compare the newest `vX.Y.Z` tag
against the baseline's current level (the latest `Merge tag 'vX.Y.Z'` commit on
`linux-voice-assistant`, or `git describe --tags`). If upstream is ahead, run the
playbook below before building, so images ship on the current release. Releases:
https://github.com/thirdreality/voice-music-assistant/releases

When upstream tags `vX.Y.Z`:

1. **Read the release notes first** (don't infer from the diff alone) and
   `git fetch upstream --tags`. Confirm linearity:
   `git merge-base --is-ancestor v<prev> v<new>`.
2. **Merge into baseline:**
   `git checkout linux-voice-assistant && git merge --no-commit --no-ff v<new>`.
3. **Resolve conflicts.** Known recurring one: `sendspin-client.cpp` (upstream
   rewrites it). Resolution: `git checkout v<new> -- <that file>`, then re-apply
   *our* `software_version`-from-env hunk. Check whether upstream has adopted any
   of our other tweaks (see watch-list) and **drop ours if it has**.
4. Commit the merge with a body documenting what upstream brought and how
   sendspin (and any other overlap) was reconciled.
5. **Parity gate:** `git diff v<new>..linux-voice-assistant` must show **only**
   the baseline custom deltas listed above — nothing else. If it does, fix before
   continuing.
6. **Propagate to feature branches** (dlna, airplay, everything), one at a time:
   `git checkout <branch> && git merge --no-commit --no-ff linux-voice-assistant`,
   resolve (README.md sometimes conflicts), commit. Then verify each branch:
   `git merge-base --is-ancestor v<new> <branch>` and that its feature files +
   plistutil/host-libplist bits are intact.
7. **Rebuild all 4 images** (clean): for `linux-voice-assistant`,
   `feat/dlna-gmediarender`, `feat/airplay-shairport-sync`, `feat/everything` —
   `rm -rf output/ && ./docker-go.sh trspk`. Builds must be **sequential**
   (all branches share one `output/` + working tree). A batch script lives at
   `/tmp/voice-music-build/batch-*.sh`.
8. Don't `git push` or delete branches unless asked. Offer to clean stale
   `image/*` from prior releases when done.

### Reconciliation watch-list

As upstream catches up, our patches can become redundant — check each release:
- **client_id from friendly_name** — adopted upstream in v1.1.9
  (`config.client_id = friendly_name`); we **dropped ours**.
- **software_version from env** — still ours as of v1.2.0; keep until upstream
  stops hardcoding `"1.0.0"` (now ~line 895 of the rewritten `sendspin-client.cpp`).
- **Wake-word location/schema** — changed at **v1.2.0** (Python→C++ migration):
  models moved to `linux-voice-assistant-cpp/wakewords/openwakeword/` with the
  new `type:"open"` manifest schema. Future merges: keep our two models there;
  don't let them drift back to the dead Python package.
- If upstream ever ships AirPlay 2, DLNA, the wake-word models, or the
  MODVERSIONS fix natively, retire our version in favor of theirs.

## Known harmless noise

- During builds, KDE/drkonqi reports `…/<pkg>/conftest has encountered a fatal
  error` — these are **autoconf feature probes that intentionally crash**; the
  host `core_pattern` → systemd-coredump → drkonqi surfaces them. **Not** build
  failures. The user chose to **live with the notifications** rather than silence
  drkonqi (real errors shouldn't be masked). Don't try to suppress them.
- A real build failure looks like `make: *** […] Error N` / `configure: error:`
  in the log, not a drkonqi popup.

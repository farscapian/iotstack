# Automatic Fallback to Bootstrap (design)

Status: DESIGN / NOT IMPLEMENTED. This doc proposes wiring up automatic
recovery from a broken production image back to the bootstrap partition.
Today every switch into bootstrap is manual/deliberate.

Related: [DUAL_PARTITION_OTA.md](DUAL_PARTITION_OTA.md) (older aspirational doc
that claims "automatic fallback"; that behaviour was never implemented and its
flash layout predates the current ota_0/ota_1 table), [partitions.md](partitions.md),
[gotchas.md](gotchas.md) (bootstrap-mediated OTA), [flash-encryption.md](flash-encryption.md)
(eFuse anti-rollback -- a DIFFERENT feature, see the warning below).

## The gap

The partition table is two app slots: `bootstrap` (ota_0, permanent) and
`production` (ota_1, the only OTA target). See
`yamls/iotstack_partition_table.csv`.

Every path that moves a device into bootstrap today is manual:

- Boot button, 3s hold -> `PartitionManager::toggle_boot_partition()`
- `switch_to_bootstrap` API service -> `PartitionManager::boot_bootstrap()`
  (called by `iotstack update`); see `yamls/common/partition_manager_production.yaml`
- Script / USB at flash time

There is no boot-failure counter and no rollback config anywhere in the tree.
A production image that crash-loops just reboots into itself forever. If the
failure also kills networking (bad NVS, driver panic), the device is
USB-recovery-only with no operator signal that anything switched.

## Why ESPHome safe_mode does NOT solve this

ESPHome's `safe_mode` component recovers on the *same* running slot -- it
re-runs `App.setup()` in place and never calls `esp_ota_set_boot_partition()`.
So it cannot, by itself, revert production -> bootstrap. It is, however, a
build-time prerequisite for Layer 1 below (ESPHome ties native rollback to
safe_mode being enabled).

Note the bootstrap image is a separate case: safe_mode there is dead weight and
should be disabled, because bootstrap skips the `nvs_secrets` component that
supplies wifi creds / OTA password / API PSK, so a safe-moded bootstrap cannot
reach the network anyway. See the safe_mode discussion in [gotchas.md](gotchas.md).
That conclusion is unchanged; Layer 1 only re-enables safe_mode on *production*.

## Two failure modes, two mechanisms

### Failure mode A -- bad update (broken from the first boot)

The image is wrong the moment it boots (bad build, wrong secrets, incompatible
partition). ESP-IDF native anti-rollback covers this.

### Failure mode B -- runtime regression on an already-valid image

Production ran fine for days/weeks, then starts crash-looping (bad NVS write,
slow leak that OOM-panics, wifi/thread driver wedge). Native rollback does
NOT help here, because the image was already marked valid long ago. This is the
case that motivated this doc and needs custom logic (Layer 2).

## Layer 1 -- ESP-IDF native anti-rollback (covers mode A)  [TODO -- item (b)]

ESPHome exposes the ESP-IDF feature:

```yaml
esp32:
  framework:
    advanced:
      enable_ota_rollback: true   # -> CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE
```

Behaviour: a freshly-switched production image boots as `PENDING_VERIFY`; if it
does not call `esp_ota_mark_app_valid_cancel_rollback()` within the first boot,
the bootloader reverts to the last-valid slot -- bootstrap -- automatically, with
no code from us. That mark-valid call lives inside `safe_mode`.

Consequences / requirements:

- Production images MUST keep `safe_mode` enabled. ESPHome silently disables
  rollback if safe_mode is off (see `esphome/components/esp32/__init__.py`,
  "OTA rollback requires safe_mode"). This is the one place the "disable
  safe_mode" advice reverses -- but only for production, never for bootstrap.
- Coverage is the FIRST-boot window only. Once production self-confirms
  (safe_mode `boot_is_good_after`, default 60s), a later regression will not
  trigger native rollback. That is what Layer 2 is for.

WARNING: `enable_ota_rollback` -> `CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE` is the
benign confirm-or-revert feature. It is NOT `CONFIG_BOOTLOADER_APP_ANTI_ROLLBACK`,
the eFuse-burning security feature that can permanently forbid booting an older
secure-version image. Do not conflate them, especially alongside the
flash-encryption work in [flash-encryption.md](flash-encryption.md).

MUST VERIFY before enabling: iotstack writes the production image into ota_1
while running on bootstrap, then switches the boot slot on a *separate* reboot
(bootstrap-mediated OTA, see [gotchas.md](gotchas.md)). Native rollback depends
on the switched-into image actually entering the `PENDING_VERIFY` state on that
next boot. Confirm on-device that the state is set by this split
write-then-switch flow, not only by the single-boot esp_ota_end() path ESP-IDF
assumes. If `PENDING_VERIFY` is not reached, Layer 1 is inert and only Layer 2
protects the device.

## Layer 2 -- boot-health watchdog in partition_manager (covers mode B)

Net-new logic, production-only. Conceptually this is safe_mode's boot-loop
counter, but the action is "flip the slot" instead of "recover in place":

1. Persist a boot-attempt counter. Reuse the NVS namespace partition_manager
   already opens (`refresh_image_hashes_()`), or an RTC var like safe_mode's.
2. Increment it early on every boot.
3. Clear it once the device proves healthy.
4. After N consecutive unhealthy boots, call the existing `boot_bootstrap()`
   and reboot.

Design decisions to pin down before coding:

- Definition of "healthy". Too early (reached setup()) misses post-connect
  crashes; too late bounces fine devices into bootstrap. Candidate bar: API
  client connected, OR uptime past a threshold (align with safe_mode's
  `boot_is_good_after`, ~60s), whichever comes first.
- Threshold N > 1, so a single power-loss mid-session is not counted as a
  failure. Suggest N = 3 to start.
- Bootstrap is the floor and must stay dependably bootable. If both slots
  crash the device is USB-only. This is the reason to keep the bootstrap image
  lean (and, per above, to disable safe_mode there rather than add logic).
- Production-only. Must not interfere with the manual `switch_to_bootstrap`
  flow, the boot-button toggle, or the otadata sequence.
- Operator signal. When the watchdog flips to bootstrap it should leave a
  breadcrumb (log line + ideally an NVS "fell_back_from_production" marker)
  so `iotstack logs` / discovery can show the device fell back rather than was
  switched on purpose.

Interaction with Layer 1: complementary, not redundant. Layer 1 catches the
bad-update first-boot window for free; Layer 2 catches everything after the
image is marked valid. Ship Layer 1 first (cheap), Layer 2 second.

## Proposed sequencing

1. Disable safe_mode on the bootstrap image (already agreed, separate change).
2. TODO (b): enable `enable_ota_rollback` on production builds, keep safe_mode
   on production, and verify `PENDING_VERIFY` is reached under the
   write-then-switch flow.
3. Implement the Layer 2 watchdog in `partition_manager` once the "healthy"
   signal and threshold are settled here.

## Open questions

- Does the bootstrap-mediated write-then-switch flow set `PENDING_VERIFY`?
  (Blocks Layer 1 correctness -- see MUST VERIFY above.)
- Best "healthy" signal for Layer 2 -- API-connected vs uptime vs both.
- Should the Layer 2 fallback be latching (stay in bootstrap until an operator
  re-pushes production) or one-shot (try production again after a cooldown)?
  Latching is safer against flapping; one-shot self-heals transient faults.

# Security (iotstack-specific)

> Generic rules (never echo secrets, env hygiene): see `.agentstack/docs/security.md`.

## OTA password handling

```bash
# OK: password in env var, not printed
export OTA_PWD="actual_password"
iotstack update bleproxy --ota-password "$OTA_PWD"
unset OTA_PWD

# FAIL: password on command line or echoed
iotstack update bleproxy --ota-password "actual_password"
echo "[OK] OTA password: $password"
```

## Pass password handling

**When using `pass insert` to store secrets, ALWAYS echo the password TWICE** (for confirmation):

```bash
# OK: password echoed twice
{ echo "$password"; echo "$password"; } | pass insert -f "iotstack/default/roles/bleproxy/ota_password"

# FAIL: password only echoed once (WILL FAIL SILENTLY)
echo "$password" | pass insert -f "iotstack/default/roles/bleproxy/ota_password"
```

**Why:** `pass insert` requires confirmation like interactive entry. Single echo fails silently (exit 1).

**Applies to:** `setup.sh`, `scripts/iotstack-secrets`, `scripts/ha-websocket-query.sh`, and any script using `pass insert`.

## Bootstrap API encryption (zero-trust LAN)

All network devices are untrusted. The bootstrap firmware's native API (port
6053) is **encrypted** with a noise PSK; the tooling never connects to it in
plaintext.

**Threat closed:** the provision/reassign path (`update_nvs_secrets`) sends
`wifi_password`, `prod_api_key`, `thread_tlv`, and `ota_password`. Before
encryption, a passive LAN sniffer captured every device + network credential in
one reassign. The API is now noise-encrypted end to end, so those payloads are
never exposed on the wire.

**Key: `boot_api_key` (per-device, out-of-band).**

- Derivation mirrors the production API key: `sha256(<role master> | <mac>)`,
  where the role master lives in pass at
  `iotstack/<env>/roles/<bootstrap-role>/api_encryption_key` (auto-generated on
  first flash). See `iotstack_bootstrap_device_api_key` in `scripts/iotstack-bootstrap.sh`.
- Written to device NVS **only over USB** by `scripts/write-nvs-secrets.sh` at
  flash time -- the trusted out-of-band channel. It is **never** included in the
  `update_nvs_secrets` API payload (`--print-api-json` deliberately omits it).
- Applied at boot in `bootstrap.yaml` via `nvs_secrets` (`api_nvs_key:
  boot_api_key` -> `set_noise_psk`). `api: encryption: {}` enables noise
  support (`USE_API_NOISE`) with no key baked into the binary.

**No plaintext fallback (fail closed).**

- Firmware: `nvs_secrets` is configured `require_api_encryption: true`, so
  `update_nvs_secrets` is **refused** unless a PSK was applied at boot. A keyless
  or erased device therefore cannot be driven over a plaintext API; recovery is
  **USB-only** (`write-nvs-secrets.sh`).
- Tooling: `_call_bootstrap_api_service` connects only with the derived PSK and
  sets `IOTSTACK_API_REQUIRE_NOISE=1`, which disables the plaintext downgrade in
  `scripts/esphome_service.py` for secret-bearing calls. If the PSK cannot be
  derived (role master absent) or the encrypted handshake fails, the call fails
  and the caller falls back to USB provisioning -- it never sends secrets in the
  clear.

> Migration: devices flashed with a pre-encryption bootstrap image have no
> `boot_api_key` and serve a plaintext API. The tooling will not talk to
> them over the API (encrypted handshake fails); reflash the bootstrap image over
> USB (which writes `boot_api_key`) to bring them onto the encrypted path.

> **Status:** implemented in firmware + tooling; **requires hardware validation**
> before it is relied upon in the field (no ESP32 available at implementation
> time). Validate: encrypted `update_nvs_secrets` succeeds on a keyed device, and
> is refused on an erased device.

## OTA password is now actually enforced on-device

`nvs_secrets` reads an OTA password from NVS on every image (`ota_password`
key on bootstrap; `bootstrap_ota_from_prod_pw` on the opt-in production
endpoint -- see below), but historically never applied it to ESPHome's `ota:`
component -- the value was read into `ota_password_` and never used, so the
OTA endpoint accepted uploads authenticated by network reachability alone.
`apply_ota_password_()` (`nvs_secrets.cpp`, called from `setup()`) now pushes
it into the `ota:` component via `set_auth_password()`, mirroring the
existing `apply_api_encryption_key_()` pattern. This requires the `ota:`
block to declare a `password: ""` placeholder (never used as-is -- it just
compiles in ESPHome's `USE_OTA_PASSWORD` code path) and `nvs_secrets` to be
told which `ota:` instance to apply to via a new `ota_id:` config key.

> **Status:** same caveat as above -- requires hardware validation (a wrong
> or missing OTA password must now be genuinely rejected, not silently
> accepted).

## Bootstrap-from-production OTA secret (`iotstack ota-bootstrap`)

Opt-in feature (`IOTSTACK_ENABLE_BOOTSTRAP_OTA`, see `docs/.env.example` and
`docs/features.md`) that lets a running production device accept an OTA
write into its own bootstrap partition. Uses a **distinct** pass-store
secret from the existing bootstrap-mode OTA secret
(`iotstack_bootstrap_pass_ota_read` / `iotstack/<env>/roles/<bootstrap-role>/ota_password`):

```
iotstack/<env>/roles/bootstrap-ota-from-production/ota_password
```

(`iotstack_prod_bootstrap_ota_pass_path` / `_read` in
`scripts/iotstack-bootstrap.sh`; per-device password is
`sha256(secret|mac)[:32]`, same derivation as everywhere else.)

**Why a separate secret, not reuse:** the existing bootstrap-mode secret's
trust boundary is "the operator already deliberately switched this device
into recovery mode" (itself gated behind `switch_to_bootstrap`, which
requires production's encrypted API). This new secret's trust boundary is
"leaking it lets anyone on the LAN overwrite the recovery partition of an
otherwise healthy, in-service production device" -- a materially different
and higher-stakes boundary. Keeping them separate lets an operator rotate or
disable "OTA bootstrap from production" fleet-wide (e.g. after a one-time
patch campaign) without touching the unrelated recovery-mode secret, and
keeps `pass show`/audit trails distinguishing the two operations.

Provision it the same way as any other OTA password (see "Pass password
handling" above -- echo twice):

```bash
{ echo "$password"; echo "$password"; } | pass insert -f "iotstack/default/roles/bootstrap-ota-from-production/ota_password"
```
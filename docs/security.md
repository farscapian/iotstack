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
{ echo "$password"; echo "$password"; } | pass insert -f "iotstack/roles/bleproxy/ota_password"

# FAIL: password only echoed once (WILL FAIL SILENTLY)
echo "$password" | pass insert -f "iotstack/roles/bleproxy/ota_password"
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
  `iotstack/roles/<bootstrap-role>/api_encryption_key` (auto-generated on first
  flash). See `iotstack_bootstrap_device_api_key` in `scripts/iotstack-bootstrap.sh`.
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
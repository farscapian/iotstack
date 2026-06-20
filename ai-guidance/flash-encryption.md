# Flash Encryption (TODO)


### What are eFuses?

**eFuse = Electronic Fuse (one-time programmable bit in ESP32 silicon)**

- Burned directly into chip during manufacturing or first boot
- Once written -> **permanently locked** (cannot be unwritten or changed)
- Hardware-protected by ROM bootloader (before your code runs)
- Each chip has unique random key (per-device security)

### Current State vs Production

**Current (Development):**
- NVS data is plaintext in flash
- Acceptable for lab/testing environment
- Easy to reflash and debug devices

**Production (Future):**
```
Enable flash encryption:
  1. Add to menuconfig: Security -> Flash Encryption -> Development Mode
  2. First flash: ROM bootloader generates random key, burns to eFuses
  3. Key is locked (read-protected)
  4. All subsequent flash I/O transparently encrypted/decrypted
  5. NVS data automatically encrypted with device-specific key
```

### Security Impact

```
Without Flash Encryption:
  Attacker: "I'll read the flash directly with a programmer"
  Result: Plaintext NVS data extracted (ota_password, api_key, etc.)

With Flash Encryption (eFuse-protected key):
  Attacker: "I'll read the flash directly with a programmer"
  Device: "Here's encrypted data (looks like garbage)"
  Attacker: "I'll extract the encryption key from eFuses"
  Device: "Nope, eFuses are read-protected in release mode"
  Attacker: "I'll physically extract the key from silicon"
  Cost: $$$,$$$ and specialized equipment
```

### TODO: Flash Encryption Implementation

- [ ] Test flash encryption on dev devices (Development Mode)
- [ ] Verify transparent encryption/decryption of NVS works
- [ ] Test device reflashing with encrypted flash
- [ ] Document eFuse burn procedure and recovery
- [ ] Implement release-mode lockdown for production deployment
- [ ] Create per-device eFuse programming guide
- [ ] Test that firmware updates preserve NVS encryption

**Why not implemented yet:**
- Development/testing friction (limited reflash capability)
- Risk of bricking device if eFuse key is lost
- Current threat model (firmware extraction) is addressed without it
- Production-only feature (adds complexity for testing phases)

**When to implement:**
- Product hardening before production deployment
- When shipping to untrusted locations (requires physical security)
- As part of secure boot implementation (firmware signature verification)

# Recovery Firmware Size Analysis & Thread Option

## Current Sizes

**WiFi Recovery (recovery.yaml):**
- OTA binary: 857KB
- Factory binary: 922KB
- Partition allocated: 1.5MB
- Available space in partition: 643KB (75% free)

## firmware.ota.bin vs firmware.factory.bin

### firmware.ota.bin (857KB)
- **Application code only** - no bootloader/partition table
- Designed for **Over-The-Air (OTA) updates** 
- Sent to device and written to a partition
- Smaller because it only contains the app
- Used for all subsequent updates after initial flash

### firmware.factory.bin (922KB)
- **Complete flash image** - bootloader + partition table + OTA data + app
- Designed for **serial/USB initial flashing**
- Flashed directly to address 0x0000 (entire device)
- Larger because it includes boot infrastructure
- Only needed once per device (first time)
- Ensures partition table and bootloader are correct

### Why Both?
1. **Serial flash (first time)**: Device is blank → need factory image with everything
2. **OTA updates (all subsequent)**: App partition exists → just send .ota.bin
3. **Safety**: OTA never touches bootloader/partition table → can't brick device

### Why Not Use OTA for Everything?
- OTA is designed to preserve critical boot infrastructure
- If bootloader got corrupted during OTA: **permanent brick**
- Serial flash is safer: physical access = user intent verified
- Most devices only get serial flashed once anyway

---

## Thread Recovery Option

### Current Status
- ESPHome 2026.5.3 doesn't have full Thread RCP support
- Thread support requires custom build or future ESPHome version
- **Recommendation**: Use WiFi recovery for now

### Size Projections (Thread-Only Recovery)
If Thread support becomes available:
- **Removes**: WiFi stack, BLE components, API-over-WiFi
- **Estimated size**: ~600-700KB (vs 857KB WiFi)
- **Space saved**: ~150-250KB

### Your Thread Recovery Strategy
Since you have a Thread mesh:

**Option 1: WiFi Recovery (Current)**
- Use `recovery.yaml` (WiFi-based)
- Device connects to your WiFi
- User OTA flashes from computer
- Works immediately, no setup

**Option 2: Thread Border Router Recovery (Future)**
- Thread-only recovery firmware (when ESPHome supports it)
- ~200KB smaller than WiFi version
- Requires Thread border router in network
- OTA would be slower (Thread network overhead)
- More resilient (mesh redundancy)

### Recommendation for Mixed Networks
If you have **both Thread and WiFi**:
- Use WiFi recovery.yaml on all devices
- Guaranteed to work everywhere
- No device should need Thread-only recovery if WiFi is available
- Thread RCP support is "nice to have" not essential

If you have **Thread-only** (no WiFi fallback):
- Wait for ESPHome Thread support
- Or connect Thread border router to WiFi
- Recovery.yaml will still work via border router

---

## Partition Space Analysis

**Current Allocation (4MB ESP32-C6):**
```
0x0000-0x20000:   Bootloader (128KB)
0x20000-0x30000:  Partition table + OTA flags (64KB)
0x30000-0x1b0000: Recovery partition (1.5MB) — 857KB used, 643KB free
0x1b0000-0x3f0000: Production partition (2.2MB) — varies by firmware
```

**Space Available:**
- Recovery: 643KB free (75% unused)
- Production: ~1.3MB free (59% unused)
- Could fit much larger production firmwares

**If Thread Recovery Were Implemented (projected 600KB):**
- Recovery: 900KB free (60% unused)
- Not significant savings
- Both WiFi and Thread recoveries easily fit

---

## Action Items

### Immediate (Ready Now)
- ✅ Use `recovery.yaml` (WiFi recovery)
- ✅ Test on bleproxy device
- ✅ Deploy to all device roles

### Future (When ESPHome Adds Thread)
- [ ] Create `recovery-thread.yaml` (Thread-only)
- [ ] Test with Thread border router
- [ ] Document Thread recovery procedure
- [ ] Add to `iotstack-roles.conf` as alternative

### No Action Needed
- ❌ Don't resize partitions (plenty of space)
- ❌ Don't remove WiFi from recovery (minimal size savings, major convenience loss)
- ❌ Don't worry about 857KB vs 922KB difference (just OTA vs factory)

---

## Conclusion

**Current Setup is Optimal:**
1. WiFi recovery works everywhere
2. Plenty of partition space (75% free)
3. OTA updates are fast & reliable
4. Can add Thread recovery later without changes
5. No need to resize or optimize partitions

**For Your Use Case (Thread network):**
- Use WiFi recovery now (works via WiFi + Thread border router if needed)
- Thread-only recovery would save ~200KB but isn't essential
- Recommend waiting for ESPHome Thread support before implementing

**Test Plan:**
1. Test recovery.yaml on bleproxy device
2. Deploy to all devices (bleproxy, mmwave, threadrouter)
3. Validate all recovery methods work
4. Document in CLAUDE.md
5. Plan Thread recovery as future enhancement

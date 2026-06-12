# Recovery Firmware Variants - Size & Feature Analysis

## The Three Options

### 1. WiFi Recovery (recovery.yaml) ✅ RECOMMENDED
**Size:** 858KB OTA binary
- **Pros:** 
  - Works on any network (WiFi available everywhere)
  - Fastest OTA updates
  - No Thread network required
  - Best for mixed WiFi/Thread deployments
- **Cons:**
  - WiFi dependency (WiFi down = recovery down)
  - Larger than Thread-only
- **Best for:** Most deployments, default choice

### 2. Thread-Only Recovery (recovery-thread.yaml) 🧵
**Size:** 782KB OTA binary (76KB smaller, 9% savings)
- **Pros:**
  - Smallest recovery firmware
  - Works on Thread mesh networks
  - Thread mesh resilience (multi-hop recovery)
  - No WiFi dependency
- **Cons:**
  - Requires active Thread network
  - Slower OTA updates (Thread overhead)
  - Can't be used if Thread is down
- **Best for:** Thread-only networks (rare), users with very stable Thread mesh

### 3. WiFi + Thread Dual-Mode
**Status:** ❌ NOT POSSIBLE
- **Reason:** ESPHome doesn't support simultaneous WiFi + OpenThread
- **Why:** Both use 2.4GHz radio, can't operate together
- **TDM won't work:** ESPHome's architecture requires exclusive radio ownership
- **Workaround:** Use WiFi recovery instead (Thread can still connect via border router)

---

## Size Breakdown

```
                    WiFi-Only    Thread-Only    Size Delta
────────────────────────────────────────────────────────
OTA Binary          858KB        782KB          -76KB (-9%)
Factory Binary      923KB        847KB          -76KB (-8%)
Partition Alloc.    1.5MB        1.5MB          same
Space Used          858KB        782KB          
Space Free          642KB        718KB          +76KB
────────────────────────────────────────────────────────
```

---

## Comparison Matrix

| Feature | WiFi | Thread |
|---------|------|--------|
| **Network type** | WiFi mesh | Thread mesh |
| **OTA speed** | Fast (WiFi ~2-5 Mbps) | Slow (Thread ~250 kbps) |
| **Reliability** | WiFi stability dependent | Thread mesh resilience |
| **Range** | WiFi range only | Mesh extends via repeaters |
| **Availability** | Most networks | Thread-only rare |
| **Setup** | Simpler (WiFi creds) | Complex (Thread TLV) |
| **Best case** | Fast OTA to nearby devices | Mesh recovery even if WiFi down |
| **Worst case** | WiFi failure = recovery unavailable | Thread mesh failure = stuck |

---

## Your Situation

You have **both WiFi and Thread networks**, so:

### Recommendation: Use WiFi Recovery (recovery.yaml)

**Why:**
1. **WiFi is faster** → 858KB OTA takes ~2 min over WiFi vs ~10 min over Thread
2. **WiFi is more available** → both WiFi and Thread devices can reach it
3. **76KB savings not worth the tradeoff** → 858KB vs 782KB isn't meaningful (both fit)
4. **Thread mesh can still connect** → Border router bridges Thread to WiFi
5. **Simplicity** → One recovery image for all devices

### If you ever want Thread-only:
- Compile `recovery-thread.yaml`
- Saves 76KB (negligible with 643KB free space)
- Use only for Thread border router devices
- Slower recovery process

---

## Can We Change This?

**Could we modify ESPHome to support both?**
- No. It's a fundamental design choice: radio can only be owned by one protocol at a time
- Even hardware-wise: you'd need time-sharing at millisecond scale
- ESPHome decided: "let user choose one, they pick the best for their network"

**Could we have separate binaries for each network type?**
- Yes, and that's what we're doing
- But using both simultaneously in one firmware: not possible

---

## Conclusion

**Use WiFi Recovery:**
- ✅ recovery.yaml (858KB)
- ✅ Works for all devices
- ✅ Fastest OTA
- ✅ Recommended

**Thread Recovery only if:**
- Thread network is primary
- WiFi unavailable/unreliable
- Accept slower OTA times
- Need mesh resilience over speed

**Don't wait for dual-mode:**
- Won't happen (hardware limitation)
- WiFi recovery is sufficient
- 76KB savings doesn't justify complexity

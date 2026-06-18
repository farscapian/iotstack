# Dual Partition OTA Recovery Implementation

## Overview

Recovery mechanism for ESP32-C6 devices with dual firmware partitions:
- **Recovery Partition**: Fixed recovery firmware (never changes, well-known credentials)
- **Production Partition**: Updatable production firmware (rotates secrets)
- **Automatic Fallback**: If production fails -> device boots recovery automatically
- **Remote Recovery**: User recovers device via OTA from computer (no physical visits)

## Architecture

### Flash Layout (4MB ESP32-C6)

```
Address    Size      Purpose
---------------------------------
0x0000     128KB     Bootloader
0x20000    16KB      Partition table
0x24000    2MB       Recovery app (fixed, never changes)
0x224000   2MB       Production app (updateable)
(spare)    ~768KB    Reserved/unused
```

### Partition Table (CSV Format)

```csv
# Name,   Type, SubType, Offset,  Size,    Flags
nvs,      data, nvs,     0x9000,  0x4000,  
otadata,  data, ota,     0xd000,  0x2000,  
recovery, app,  ota_0,   0x24000, 0x200000,  
production, app, ota_1,  0x224000, 0x200000, 
```

**Key points:**
- `ota_0` = Recovery partition (Partition A)
- `ota_1` = Production partition (Partition B)  
- OTA mechanism selects which partition to write to
- Bootloader can fall back to alternate partition if boot fails

## Implementation Steps

### 1. Create Partition Table

Create `partitions/iotstack_partition_table.csv`:
```csv
# Name,   Type, SubType, Offset,   Size,    Flags
nvs,      data, nvs,     0x9000,   0x4000,  
otadata,  data, ota,     0xd000,   0x2000,  
recovery, app,  ota_0,   0x24000,  0x200000,
production, app, ota_1,  0x224000, 0x200000,
```

### 2. Configure ESP32 Board

In device YAML (or board config):
```yaml
esp32:
  board: seeed_xiao_esp32c6
  framework:
    type: esp-idf
  partitions: custom:partitions/iotstack_partition_table.csv
```

### 3. OTA Configuration

**Recovery image** (`bleproxy-recovery.yaml`):
```yaml
ota:
  - platform: esphome
    password: ${recovery_ota_password}
    # OTA writes to ota_0 partition (recovery partition)
```

**Production image** (`bleproxy.yaml`):
```yaml
ota:
  - platform: esphome
    password: ${production_ota_password}
    # OTA writes to ota_1 partition (production partition)
```

### 4. Boot Fallback Logic

ESPHome's OTA bootloader automatically:
1. Tries to boot active partition
2. If boot fails (repeated boot loops):
   - Switches to alternate partition
   - Boots from there
3. From alternate (recovery) partition, user can OTA flash active partition

**No custom code needed** - ESP-IDF bootloader handles this automatically.

## Recovery Workflow

### Three Ways to Enter Recovery Mode

#### Option 1: Automatic Fallback (No Action Needed)
```
Production firmware fails
  v
Boot loop (5 attempts) detected by bootloader
  v
Bootloader auto-switches to recovery partition
  v
Device boots recovery firmware (purple LED indicator)
```

#### Option 2: Manual Physical Button (GPIO0)
```
Hold GPIO0 boot button for 3+ seconds
  v
Device logs "switching partition"
  v
ESP32 writes OTA flags to switch partition
  v
Device reboots into alternate partition
  v
Recovery firmware boots (if production was active) or vice versa
```

#### Option 3: Home Assistant Button
```
Press "Toggle Boot Partition" button in HA
  v
Device receives command via API
  v
Partition toggle code executes
  v
LED flashes 3 times to confirm
  v
Device reboots into alternate partition
```

### Complete Recovery Scenario

```
+---------------------------------------------------+
| 1. Device boots production firmware             |
|    (on ota_1 partition)                         |
|                                                  |
| 2. Production firmware fails/crashes            |
|    Boot loop detected or user initiates toggle  |
|                                                  |
| 3. Choose entry method:                         |
|    - Wait for auto-fallback (5 boot attempts)   |
|    - Hold GPIO0 button 3+ seconds               |
|    - Press HA "Toggle Boot Partition" button    |
|                                                  |
| 4. Device boots recovery firmware               |
|    (on ota_0 partition)                         |
|    LED: Purple blink = recovery mode active     |
|                                                  |
| 5. Device connects to WiFi                      |
|    API available with recovery credentials      |
|                                                  |
| 6. User from computer:                          |
|    esphome upload yamls/bleproxy.yaml \\       |
|      --device <device>.local \\                 |
|      --ota-password IotstackRecovery2024        |
|                                                  |
| 7. OTA writes production firmware to ota_1      |
|    Set ota_1 as boot partition                  |
|                                                  |
| 8. Device reboots into production               |
|    LED: Returns to normal pattern               |
|    Normal operation resumes                     |
`---------------------------------------------------+
```

## Initial Device Deployment

### First Time Flash (Serial)

```bash
# Flash recovery firmware to device via serial
esphome upload-binary bleproxy-recovery.bin --device /dev/ttyUSB0

# Device reboots with recovery firmware on ota_0 partition
# But production partition (ota_1) is empty
```

### Flash Production via OTA

From recovery firmware, OTA flash production:
```bash
esphome upload yamls/bleproxy.yaml \
  --device bleproxy-XXXXX.local \
  --ota-password IotstackRecovery2024

# OTA writes production firmware to ota_1 partition
# Bootloader sets ota_1 as active boot partition
# Device reboots into production
```

## Key Design Decisions

### Why Recovery Credentials Are Fixed

- Recovery firmware lives in read-only recovery partition
- Can't update recovery credentials without physical access (serial flash)
- Well-known credentials enable recovery without password knowledge
- Production credentials can rotate freely without affecting recovery

### Why We Need Partition Table

- Default ESP32 config: single 2MB app partition (space for one firmware only)
- We need two app partitions: recovery (2MB) + production (2MB)
- Requires custom partition table in CSV format
- Bootloader uses partition table to select which to boot

### Fallback Mechanism

- ESP-IDF bootloader has built-in OTA fallback
- If selected partition fails to boot:
  - Bootloader detects repeated boot attempts
  - Switches to alternate OTA partition
  - Boots from there
- No custom code needed - automatic!

## Limitations & Considerations

### Flash Space
- 4MB device: 2MB recovery + 2MB production = full capacity
- Can't fit additional storage (SPIFFS, LittleFS)
- Bluetooth proxy disabled in recovery to save space

### Production Partition Selection
- OTA mechanism must know which partition is "active" for updates
- Can use OTA flags in partition table
- Or explicit partition selection in OTA command

### Testing
- Need to test automatic fallback (intentional boot loop)
- Verify OTA writes to correct partition
- Confirm partition switching works

## Testing Checklist (BLE Proxy - Phase 1)

Before rolling out to other device roles, validate bleproxy-recovery on real hardware:

### Compilation & Initial Flash
- [ ] Compile bleproxy-recovery.yaml without errors
- [ ] Flash recovery firmware via serial to a test device
- [ ] Device boots successfully, WiFi connects
- [ ] Purple LED blink pattern visible on boot

### Automatic Fallback Testing
- [ ] Modify production bleproxy.yaml to have a broken lambda (intentional failure)
- [ ] Compile and OTA flash broken production to device
- [ ] Device enters boot loop (should retry 5 times)
- [ ] After 5 boot attempts, automatically switches to recovery partition
- [ ] Device boots recovery firmware (purple LED pattern)
- [ ] WiFi connects successfully from recovery

### Manual Partition Toggle Testing
- [ ] Hold GPIO0 boot button for 3+ seconds
- [ ] LED shows toggle feedback
- [ ] Device reboots into production (or recovery if was recovery)
- [ ] Device boots successfully into switched partition

### Remote Partition Toggle (HA Button)
- [ ] Press "Toggle Boot Partition" button in Home Assistant
- [ ] LED flashes 3 times to confirm
- [ ] Device reboots into alternate partition
- [ ] Both partitions boot successfully

### OTA Recovery Testing
- [ ] With device running broken production firmware in recovery mode
- [ ] OTA flash fixed production firmware using recovery OTA password
- [ ] Device reboots into production firmware
- [ ] Production firmware boots and works correctly

### Full Cycle Testing
- [ ] Start on production firmware (working)
- [ ] Trigger intentional failure (corrupt lambda)
- [ ] Device auto-fallbacks to recovery
- [ ] OTA flash fixed firmware from recovery
- [ ] Device runs fixed production
- [ ] Cycle works reliably multiple times

### Credential Verification
- [ ] Recovery OTA password: `IotstackRecovery2024` [OK]
- [ ] Recovery API key: `IotstackRecoveryAPIKey2024` [OK]
- [ ] Only these credentials work on recovery firmware
- [ ] Production credentials don't affect recovery

### Documentation
- [ ] All three entry methods (auto, button, HA) work
- [ ] LED indicators are clear and consistent
- [ ] Recovery workflow is smooth and user-friendly
- [ ] Ready to document as official procedure

## Next Steps (After BLE Proxy Validation)

1. [OK] Create recovery YAML (bleproxy-recovery.yaml)
2. [OK] Create partition table (partitions/iotstack_partition_table.csv)
3. [TODO] **TEST on real bleproxy device** (above checklist)
4. [TODO] Create mmwave-recovery.yaml, threadrouter-recovery.yaml (copy pattern)
5. [TODO] Update iotstack-roles.conf for recovery variants
6. [TODO] Add recovery OTA scripts to iotstack.sh
7. [TODO] Test full recovery workflow on all device types

## References

- [ESP32-IDF Partition Table Docs](https://docs.espressif.com/projects/esp-idf/en/stable/esp32/api-reference/system/ota_ops.html)
- [ESPHome OTA Component](https://esphome.io/components/ota.html)
- [esp-idf bootloader OTA](https://docs.espressif.com/projects/esp-idf/en/latest/esp32/api-reference/system/ota_ops.html)

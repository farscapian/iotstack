# Partition Configuration


**Two-partition scheme:** permanent **bootstrap** (`ota_0`) + **production** (`ota_1`). All production OTA runs from bootstrap so the bootstrap image is never overwritten. Partition sizes are calculated from actual compiled firmware binary sizes.

### Calculation Process

1. **Compile bootstrap firmware** (`smart_compile`)
   - Template: `yamls/bootstrap.yaml`
   - Rendered per chip to `yamls/.iotstack-bootstrap-<variant>.yaml` (`scripts/bootstrap-yaml.sh`)
   - Output: `firmware.bin` in build directory

2. **Measure bootstrap size** and set `IOTSTACK_BOOTSTRAP_PART_SIZE`
   - Bootstrap partition = firmware size + margin, rounded up to 64 KB
   - Production partition = remaining flash after fixed NVS/OTA/metadata regions

3. **Generate partition table** (`scripts/partition-table.sh`)
   - Creates `~/.iotstack/iotstack_partition_table.csv`
   - Symlink at `yamls/iotstack_partition_table.csv` (ESPHome `!include`)
   - Bootstrap may require a second compile pass after the table is regenerated

4. **Use partition table**
   - `write-nvs-secrets.sh` reads NVS offset/size from generated CSV
   - Serial flash and assessment code use calculated production offset

### Why This Approach?

- [OK] **No hardcoded partition sizes** -- All calculated from actual firmware
- [OK] **Zero chance of misalignment** -- Partition table always matches firmware reality
- [OK] **Firmware changes auto-handled** -- Larger firmware = larger partition, calculated automatically
- [OK] **Audit-friendly** -- Partition table shows exactly what firmware needs
- [OK] **Exact fit** -- Partitions are only as large as firmware needs (no wasted flash)
- [OK] **Artifacts in ~/.iotstack** -- Generated files stored in user home, not repo

### Files Involved

- `smart_compile()`: Calls partition calculation after compilation
- `_calculate_partition_sizes()`: Determines sizes from firmware binary
- `_generate_partition_table()`: Creates CSV with calculated values
- `~/.iotstack/iotstack_partition_table.csv`: Generated output (actual file)
- `yamls/iotstack_partition_table.csv`: Symlink to ~/.iotstack/iotstack_partition_table.csv (for ESPHome)

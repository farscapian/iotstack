# ESP32 NVS Reference Projects

Local copies of open-source ESP32 projects that implement NVS (Non-Volatile Storage) for secrets management. These serve as code references and examples for best practices in handling device credentials, API keys, and other sensitive data in flash memory.

**Location:** `resources/esp32projects/`
**Directory:** All projects listed here are cloned locally (shallow clone, shallow history only)

---

## Project 1: ArduinoNvs

**Repository:** https://github.com/rpolitex/ArduinoNvs
**Local Path:** `resources/esp32projects/ArduinoNvs/`

### Purpose
Arduino-style C++ wrapper around ESP-IDF's native NVS library, simplifying the interface for storing and retrieving key-value pairs from device flash.

### Key Features
- Simple Arduino-like API for NVS operations
- Abstracts away IDF complexity
- Suitable for credential and configuration storage
- Lightweight and minimalist

### Relevant Code Patterns
- Look at the header files for C++ class design
- Review namespacing patterns
- Study error handling approach

### iotstack Relevance
Demonstrates a clean C++ abstraction for NVS. Our `nvs_secrets` component uses similar patterns for reading NVS values at runtime.

---

## Project 2: TridentTD_ESP32NVS

**Repository:** https://github.com/TridentTD/TridentTD_ESP32NVS
**Local Path:** `resources/esp32projects/TridentTD_ESP32NVS/`

### Purpose
High-level ESP32 NVS library focused on easy credential and configuration management without low-level IDF boilerplate.

### Key Features
- Namespace abstraction for organizing credentials
- Type-safe storage (strings, integers, blobs)
- Built-in default value support
- Clear error reporting

### Relevant Code Patterns
- Study namespace isolation patterns
- Review type handling for different data types
- Examine default value fallback mechanisms

### iotstack Relevance
Similar to our approach: provides clear APIs for reading credential-like data from flash. Useful for understanding namespace management and type safety.

---

## Project 3: ESPNVSValue

**Repository:** https://github.com/ulikoehler/ESPNVSValue
**Local Path:** `resources/esp32projects/ESPNVSValue/`

### Purpose
High-level API that enables custom type mapping to NVS entries, enabling storage of structured secrets and complex API keys.

### Key Features
- Custom type mapping/serialization
- Template-based type handling (C++)
- Encapsulation of NVS details
- Support for complex data types

### Relevant Code Patterns
- Study C++ template design for type safety
- Review serialization approach for complex types
- Examine error handling for type mismatches

### iotstack Relevance
Our device-specific secret derivation (`sha256(role_secret | device_mac)`) requires handling of different data types (strings, hashes, binary data). This project shows patterns for that.

---

## Project 4: ESP32_NVS

**Repository:** https://github.com/VPavlusha/ESP32_NVS
**Local Path:** `resources/esp32projects/ESP32_NVS/`

### Purpose
Direct reference implementation of ESP-IDF NVS, showing low-level usage patterns and proper initialization sequences.

### Key Features
- Low-level IDF examples
- Proper initialization and error handling
- Clear partition table setup
- Multiple namespace usage

### Relevant Code Patterns
- Study IDF initialization sequences
- Review partition table configuration
- Examine error code handling (ESP_OK, ESP_ERR_*)
- Learn proper handle lifecycle management

### iotstack Relevance
Shows how to properly initialize NVS, handle namespaces, and manage the partition lifecycle. Our `write-nvs-secrets.sh` uses similar low-level IDF patterns.

---

## Project 5: mruby-esp32-nvs

**Repository:** https://github.com/mruby-esp32/mruby-esp32-nvs
**Local Path:** `resources/esp32projects/mruby-esp32-nvs/`

### Purpose
NVS library wrapper for mruby scripting, enabling dynamic credential management without firmware recompilation.

### Key Features
- Scripting language binding to NVS
- Runtime credential updates
- Dynamic configuration without OTA
- Simplified interface for non-C++ code

### Relevant Code Patterns
- Study language binding patterns
- Review how scripting languages abstract NVS
- Examine security considerations for dynamic updates

### iotstack Relevance
Shows an alternative approach to our lazy-loading architecture: rather than embedding a component in firmware, use a scripting language for credential management. Useful inspiration for future runtime configurability.

---

## How to Use These References

### Exploring a Project
```bash
cd resources/esp32projects/<project-name>
ls -la                    # View directory structure
cat README.md             # Read project documentation
grep -r "nvs_open" .      # Find key NVS operations
```

### Comparing Approaches
Compare how each project handles:
1. **Initialization**: How do they set up NVS?
2. **Error handling**: What patterns for ESP_OK checks?
3. **Namespaces**: How do they organize credentials?
4. **Type safety**: How do they handle different data types?
5. **Cleanup**: How do they handle resources?

### Integration Ideas
- Consider adopting a simpler abstraction layer (like ArduinoNvs) if our current approach becomes too complex
- Review TridentTD's namespace patterns if we need more organization
- Study ESPNVSValue's serialization if we add more complex secret types
- Reference ESP32_NVS for proper IDF initialization sequences
- Explore mruby patterns if we want dynamic runtime configuration

---

## iotstack vs Reference Projects

| Aspect | iotstack | Reference Projects |
|--------|----------|-------------------|
| **Architecture** | Device-specific secrets derived at flash time, written to NVS | General-purpose NVS libraries |
| **Secret Scope** | Role-based → device-specific derivation | Per-device or per-app |
| **Runtime Loading** | ESPHome components read at startup | Various (direct calls, scripting, etc.) |
| **Serialization** | SHA256 hashes, simple strings | Variable (custom types, blobs, etc.) |
| **Use Case** | Multi-device fleet with unique credentials | Single device or simpler configs |

---

## Security Considerations

All projects store NVS data as plaintext in flash. For production hardening:
- **Flash Encryption**: Enable eFuse-protected encryption of NVS partition
- **Secure Boot**: Verify firmware signatures before running
- **Access Control**: Restrict who can read NVS via API

See [CLAUDE.md → Flash Encryption & eFuses](../CLAUDE.md#flash-encryption--efuses---production-enhancement-todo) for iotstack's production hardening plan.

---

## Notes

- All projects cloned with `--depth 1` (shallow clone with minimal history)
- These are static references; they're not auto-updated
- Check individual project READMEs for licensing and usage restrictions
- This directory is `.gitignored` to keep the main repo lightweight

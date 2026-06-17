# iotstack Command Help Documentation

Detailed help and technical documentation for iotstack commands.

Each file contains in-depth information about a command beyond what the help text shows.

## Files

- **update.txt** - Compile and flash devices over-the-air (OTA)
  - Security best practices for passwords
  - Delta mode and build hashing
  - Parallel flashing and job control
  - MAC address targeting for specific devices

- **flash.txt** - Serial flash tool for device setup and recovery
  - Dual-partition OTA architecture explanation
  - Serial flash timing expectations
  - USB auto-detection behavior
  - Recovery mode procedures

- **reassign.txt** - Flash specific devices to a different configuration
  - Password handling and security
  - Home Assistant entity ID updates
  - Device role switching scenarios

- **query.txt** - Query Home Assistant device and entity registry
  - Dependencies and auto-installation
  - Home Assistant configuration steps
  - Entity output format and attributes
  - WebSocket API implementation details

- **secret.txt** - Retrieve encrypted secrets from pass store
  - Secret storage architecture
  - Versioned secrets and recovery
  - OTA password vs API encryption key
  - Security implications and threat model

## Usage

Access from the command line:
```bash
iotstack <command> help        # Quick help in terminal
cat docs/help/<command>.txt    # Detailed documentation
```

## When to Use These Docs

Read these files when you need to understand:
- Security implications of password handling
- Advanced features and configuration
- Technical architecture and design
- Troubleshooting and recovery procedures
- Integration with Home Assistant

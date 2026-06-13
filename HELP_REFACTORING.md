# Help Text Refactoring

## Status: Help Text Extracted (Ready for Shell Function Updates)

All help text has been extracted from embedded heredocs in `iotstack.sh` into separate files in `docs/help/` for easier maintenance and editing.

## File Organization

### Quick-Reference Files (`iotstack-*.txt`)
Used when user runs `iotstack help` or `iotstack <command> help`. Concise, terminal-friendly format with 80-char line wrapping.

- `iotstack.txt` — Main help (all commands)
- `iotstack-update.txt` — Update command quick reference
- `iotstack-verify.txt` — Verify command quick reference
- `iotstack-list.txt` — List command quick reference
- `iotstack-reassign.txt` — Reassign command quick reference
- `iotstack-flash.txt` — Flash command quick reference
- `iotstack-query.txt` — Query command quick reference
- `iotstack-secret.txt` — Secret command quick reference
- `iotstack-rotate-secrets.txt` — Rotate-secrets command quick reference
- `iotstack-clean.txt` — Clean command quick reference
- `iotstack-commission.txt` — Commission command quick reference

### Detailed Documentation Files (`iotstack-*-detailed.txt`)
In-depth guides covering security, architecture, and advanced usage. Each quick-reference file links to its corresponding detailed file.

- `iotstack-update-detailed.txt` — Password security, delta mode, parallel flashing, MAC targeting
- `iotstack-flash-detailed.txt` — Dual-partition architecture, timing expectations, USB detection, recovery mode
- `iotstack-reassign-detailed.txt` — Password handling best practices, password list mode, HA entity updates, role switching
- `iotstack-query-detailed.txt` — Dependencies, HA configuration, entity output format, WebSocket API
- `iotstack-secret-detailed.txt` — Storage architecture, versioned secrets, secret types, rotation, security model
- `iotstack-rotate-secrets-detailed.txt` — Versioning system, device updates, OTA vs API keys, automation, disaster recovery
- `iotstack-commission-detailed.txt` — Matter protocol overview, Thread setup, HA integration, QR code handling, troubleshooting

### Documentation Index
- `README.md` — Overview of all help documentation files

## Next Step: Update iotstack.sh Functions

The shell functions in `iotstack.sh` currently use embedded heredocs (e.g., `cat << 'EOF' ... EOF`). These should be updated to load from the extracted files:

### Current Pattern (to be replaced):
```bash
help_update() {
  cat << 'EOF'
iotstack update — Compile and flash device(s)...
...
EOF
}
```

### Target Pattern:
```bash
help_update() {
  cat "${SCRIPT_DIR}/docs/help/iotstack-update.txt"
}
```

## Functions to Update

- `usage()` → Load `docs/help/iotstack.txt`
- `help_update()` → Load `docs/help/iotstack-update.txt`
- `help_verify()` → Load `docs/help/iotstack-verify.txt`
- `help_list()` → Load `docs/help/iotstack-list.txt`
- `help_reassign()` → Load `docs/help/iotstack-reassign.txt`
- `help_flash()` → Load `docs/help/iotstack-flash.txt`
- `help_query()` → Load `docs/help/iotstack-query.txt`
- `help_secret()` → Load `docs/help/iotstack-secret.txt`
- `help_rotate_secrets()` → Load `docs/help/iotstack-rotate-secrets.txt`
- `help_clean()` → Load `docs/help/iotstack-clean.txt`
- `help_commission()` → Load `docs/help/iotstack-commission.txt`

## Benefits

1. **Easier Maintenance**: Edit help text without modifying shell code
2. **Better Organization**: Quick-ref and detailed docs clearly separated
3. **Reusability**: Help text can be used in multiple contexts (CLI, web docs, etc.)
4. **Version Control**: Changes to documentation are clearly tracked
5. **User-Friendly**: Easier for users to find detailed information

## Files Modified

- `.gitignore` — Added exceptions for help documentation files (overrides `*secret*` pattern)
- `docs/help/` — All new help text files created

## Git Commits

1. **Extract help text into separate files** — Created all `.txt` files and updated `.gitignore`
2. **(Next) Update iotstack.sh to load from files** — Replace heredocs with file loading

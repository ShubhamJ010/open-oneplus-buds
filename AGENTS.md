# AGENTS.md

Instructions for AI agents working on `open-oneplus-buds`.

## Core Purpose

macOS menu bar app control OnePlus / Oppo / Nord audio devices via reverse-engineered BLE GATT vendor protocol (`079A` / `08A4`).

## Security Rules (CRITICAL)

1. **Never connect unpaired devices**:
   - `CBCentralManager` BLE scan find ALL devices in radio range.
   - App MUST check `IOBluetoothDevice.pairedDevices()` first.
   - Peripheral name + BD_ADDR MUST match macOS paired audio device.
   - No paired buds -> NO scan. Set `.failed(message: "No buds paired to Mac")`.

2. **Validate advertisement**:
   - Mfg payload (`0x072F`) bytes 10..15 contain reverse BD_ADDR.
   - If MAC extracted -> MUST match paired device MAC.
   - Unpaired advertisement -> drop silently. Never call `connect()`.

3. **Re-check on service discovery**:
   - If connected peripheral name not in paired list -> call `cancelPeripheralConnection()` immediately.

4. **Cache hygiene**:
   - Validate `buds.lastPeripheralUUID` and `buds.lastDeviceName` against paired list on startup.
   - Invalid -> delete from `UserDefaults`.

## Architecture

- `Sources/BudsCore`:
  - `BudsClient.swift`: BLE central manager, GATT state machine, operation queue, pairing gates.
  - `BudsDeviceFilter.swift`: Name whitelists, mfg payload parser (battery, BD_ADDR).
  - `OPOProtocol.swift`: Packet framing (`AA ...`), CRC/checksum, command definitions.
  - `ANCWireMapping.swift`: ANC modes (`on`, `off`, `transparency`) wire byte mappings.
  - `Models.swift`: `ConnectionState`, `BatteryStatus`, `ANCMode`, `EQStatus`.
- `Sources/BudsApp`:
  - SwiftUI menu bar UI, popover, liquid glass design, media monitoring.
  - `AppModel.swift`: UI state store. Sync with `BudsClient.events`.

## Bluetooth Flow

1. App launch -> check `IOBluetoothDevice.pairedDevices()`.
2. Find paired buds -> retrieve or scan BLE.
3. Peripheral found -> verify paired -> connect BLE.
4. Discover services (`079A` / `08A4`) -> find write/notify chars.
5. Send `HELLO` -> sleep 2s -> send `REGISTER` -> authenticated.
6. Popover open -> subscribe notify -> query battery.
7. User click ANC -> enqueue high-priority `ANC_QUERY` -> sleep 1.5s -> `ANC_SET`.
8. User disconnect -> drop BLE GATT + close Classic ACL link (`IOBluetoothDevice.closeConnection()`) -> buds fall back to phone.

## Build & Deploy

```bash
# Test logic
swift run BudsSelfTest

# Build debug
./scripts/build.sh debug

# Package + deploy release to ~/Applications/Buds.app
./scripts/install.sh release

# View live logs
log show --predicate 'process == "Buds"' --info --last 5m --style compact
```

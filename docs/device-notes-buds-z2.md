# Device Notes: OnePlus Buds Z2

Reverse-engineering notes and protocol details for the OnePlus Buds Z2 (Model E504A / OPOv1 family). Research conducted with Google Antigravity.

## GATT services and characteristics

Unlike Nord models that use custom 128-bit UUIDs (`0000079A-D102-11E1-9B23-00025B00A5A5`), the OnePlus Buds Z2 exposes its control channel under 16-bit based 128-bit UUIDs alongside Fast Pair (`FE2C`):

| Entity | UUID | Properties | Purpose |
| :--- | :--- | :--- | :--- |
| Command service | `000008A4-0000-1000-8000-00805F9B34FB` | None | Primary OPOv1 channel |
| Write characteristic | `00000001-0000-1000-8000-00805F9B34FB` | Write without response (`0x04`) | Send packets (`HELLO`, `REGISTER`, `SET`, `QUERY`) |
| Notify characteristic | `00000002-0000-1000-8000-00805F9B34FB` | Notify (`0x10`) | Receive responses and push telemetry |
| Telemetry service | `FE2C` | Fast Pair / GATT | Used for `retrieveConnectedPeripherals` |

When connected to macOS, calling `central.retrieveConnectedPeripherals(withServices: [CBUUID("FE2C"), CBUUID("000008A4...")])` finds the peripheral directly without an active scan.

## Authentication handshake

The earbuds require the standard handshake before accepting commands:

1. `HELLO`: `AA 07 00 00 00 01 23 00 00 12`
   - Ack: `AA 0D 00 00 00 81 23 ...`
2. `REGISTER`: `AA 0C 00 00 00 85 41 05 00 00 B5 50 A0 69` (Token: `B5 50 A0 69`)

## ANC modes and wire values

The OnePlus Buds Z2 firmware defines these states:

| Mode | Wire byte | Packet tail | Notes |
| :--- | :---: | :--- | :--- |
| Off | `0x01` | `... 01 01 01` | Passthrough, no noise control |
| Transparency | `0x02` | `... 01 01 02` | Ambient sound |
| Noise cancellation | `0x04` | `... 01 01 04` | Normal noise cancellation |
| Max noise cancellation | `0x08` | `... 01 01 08` | Max noise cancellation |

### Push notifications and gestures

When cycling modes using touch-and-hold gestures configured in HeyMelody:

- Transparency reports `AA 0B 00 00 04 02 <seq> 04 00 03 01 01 02`
- Max noise cancellation reports `AA 0B 00 00 04 02 <seq> 04 00 03 01 01 08`
- Normal noise cancellation reports `AA 0B 00 00 04 02 <seq> 04 00 03 01 01 04`
- Writing `0x08` to `00000001` activates max noise cancellation and returns `AA 08 00 00 04 84 42 01 00 00`.

### Multi-frame packet concatenation

On connection or mode switch, the earbuds often pack two frames into a single BLE notification:

```text
AA 0B 00 00 04 02 24 04 00 03 01 01 08 AA 0B 00 00 04 02 25 04 00 03 02 01 0A
```

The first frame (`... 01 01 08`) contains the ANC mode. The second frame contains volume or telemetry. Parsers should inspect each `0xAA` subframe rather than inspecting only the end of the byte buffer.

## Battery responses and case telemetry

Battery query responses arrive under `CAT=0x06 SUB=0x81 CMD=0x25`:

```text
AA 0B 00 00 06 81 25 04 00 00 <pairCount> <id> <percent>
```

When only one bud reports:
- Example: `AA 0B 00 00 06 81 25 04 00 00 01 01 5A`
- `pairCount = 0x01`, `id = 0x01` (left bud), `percent = 0x5A` (90%)
- Parsers should check `bytes.count >= 11` rather than requiring multiple pairs.

The charging case communicates via the earbuds. It does not maintain an independent BLE link to the Mac. Case battery percentage updates arrive via `CAT=0x04 SUB=0x02` telemetry when the lid opens or closes, or when a bud is placed in the case:

```text
AA 0D 00 00 04 02 <seq> 07 00 01 02 01 <casePercent> 02 <budPercent>
```

## Case open/close lifecycle and BLE advertisement telemetry

When the case lid opens, the OnePlus Buds Z2 immediately begins dual-stack transmission:
1. **Classic Bluetooth (A2DP/HFP audio)**: Paging the paired host via an incoming ACL connection.
2. **BLE manufacturer advertisements**: Emits Company ID `0x072F` (Oplus / Oppo / OnePlus) and Google Fast Pair (`0xFE2C`).

### Advertisement payload structure (Company ID `0x072F`)

Example captured live packet (21 bytes):
```text
2F 07 14 10 06 3F 00 01 98 04 ED 6F 4B 2A 0F 84 29 C8 C8 BA 01
```

- **Byte 0..1**: Company Identifier `[0x2F, 0x07]` (`0x072F` little-endian).
- **Byte 2..9**: Header and device capability flags.
- **Byte 10..15**: Earbud Bluetooth MAC address reversed (`ED 6F 4B 2A 0F 84` -> `84:0F:2A:4B:6F:ED`).
- **Byte 16**: Case state flags (`0x29` = lid open / in case; `0x39` = out of case).
- **Byte 17**: Left earbud battery (`0xC8` = 200 = 100%).
- **Byte 18**: Right earbud battery (`0xC8` = 200 = 100%).
- **Byte 19**: Case battery (`0xBA` = 186 = 93%).
- **Byte 20**: Charging state / parity indicator.

#### Percentage decoding rule
Values between `101...200` represent $2 \times \text{percentage}$ (e.g. `0xC8 = 200 -> 100%`). Values `0...100` are raw percentages.

This allows the app to extract and render accurate Left, Right, and Case battery percentages the exact millisecond the lid opens, even before the GATT connection and HELLO handshake complete.

## System audio synchronization & handshake concurrency

### 1. Dual-transport race conditions
When the case lid opens:
- macOS native `bluetoothd` accepts the incoming Classic Bluetooth audio link.
- `CBCentralManager` does not always deliver a new `didDiscoverPeripheral` advertisement if the peripheral is already connected by the system.
- To detect this instantly without polling, `IOBluetoothDevice.register(forConnectNotifications:selector:)` listens for system-level Classic connection events. Because `IOBluetooth` dispatches on a background queue, the callback must be marked `nonisolated` to avoid tripping Swift concurrency actor assertions.

### 2. Handshake serialization requirement
`didDiscoverCharacteristicsForService` is called once per service or characteristic batch.
If `HELLO` (`AA 07 00 ...`) and `REGISTER` (`AA 0C 00 ...`) are triggered asynchronously from each callback, redundant duplicate handshake packets are transmitted across GATT:
```text
[TX] HELLO: AA 07 00 00 00 01 23 00 00 12 (duplicated 3x)
[TX] REGISTER: AA 0C ... (duplicated 3x)
```
Buds Z2 firmware will abort the session and cleanly terminate GATT (`reason: 10719`) when receiving overlapping un-serialized handshakes.
**Solution**: Deduplicate GATT session readiness via `sessionReadyTriggered` and serialize the handshake through the FIFO operation queue (`enqueue(kind: .authenticate, ...)`).

---

### 3. Connection Handoff: Snatching & Releasing (Phone <-> Mac)

OnePlus Buds Z2 maintain a single active Bluetooth Classic ACL link at a time:
- **Phone to Mac ("Snatch")**:
  - When the buds are active on the phone, BLE GATT alone cannot establish the audio session on macOS.
  - `BudsClient.reconnectNow()` triggers `IOBluetoothDevice.openConnection()` on a background queue.
  - macOS sends an `HCI Create Connection` paging packet on Bluetooth Classic BR/EDR.
  - The Buds Z2 firmware prioritizes incoming baseband paging from a paired host, dropping the phone ACL link and connecting to Mac.
  - macOS system audio registers the connect event via `IOBluetoothDevice.register(forConnectNotifications:)`, which immediately establishes the CoreBluetooth GATT session.
- **Mac to Phone ("Give back / Disconnect")**:
  - The app terminates GATT and calls `IOBluetoothDevice.closeConnection()`.
  - Dropping the Mac ACL link triggers the Buds Z2 internal fallback logic: the earbuds automatically reconnect to the previously connected paired phone.
  - Exposed in the UI via the Header Card close button (`x`) with a confirmation popover, and via two-finger / secondary-click on the macOS menu bar icon.



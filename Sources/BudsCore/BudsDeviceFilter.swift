import Foundation
import CoreBluetooth

public enum BudsDeviceFilter {
    /// Determines whether a device name indicates an audio device (earbuds, earphones, headphones, neckbands).
    /// Pure whitelist based on product keywords and audio taxonomy — no device-specific model blacklists.
    public static func isAudioDeviceName(_ rawName: String?) -> Bool {
        guard let rawName, !rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        let name = rawName.lowercased()

        // 1. Direct earbud/headphone model keywords across OnePlus & sister lines
        if name.contains("buds") || name.contains("bullets") {
            return true
        }

        // 2. Generic audio terminology combined with OnePlus / Nord / Oppo branding
        let isBrand = name.contains("oneplus") || name.contains("nord") || name.contains("oppo")
        let isAudio = name.contains("earphone") ||
                      name.contains("headphone") ||
                      name.contains("headset") ||
                      name.contains("in-ear") ||
                      name.contains("audio") ||
                      name.contains("wireless")

        return isBrand && isAudio
    }

    /// Evaluates whether an advertised BLE peripheral is a supported OnePlus audio device.
    /// Prioritizes manufacturer GATT service UUIDs, then falls back to audio device name taxonomy.
    public static func matchesAdvertisement(peripheralName: String?, advertisementData: [String: Any]) -> Bool {
        // 1. Fast-path: Explicit advertisement of OnePlus vendor GATT services (079A or 08A4)
        if let uuids = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            let targetUUIDs = [
                CBUUID(string: OPOProtocol.service079A),
                CBUUID(string: OPOProtocol.service08A4),
                CBUUID(string: OPOProtocol.serviceFE2C)
            ]
            if uuids.contains(where: { targetUUIDs.contains($0) }) {
                return true
            }
        }

        // 2. Fast-path: Manufacturer data with OnePlus/Oppo Company ID 0x072F ([0x2F, 0x07])
        if let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, mfg.count >= 2 {
            let bytes = [UInt8](mfg)
            if bytes[0] == 0x2F && bytes[1] == 0x07 {
                return true
            }
        }

        // 3. Fast-path: Google Fast Pair Service Data (0xFE2C)
        if let svcData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
            if svcData.keys.contains(where: { $0.uuidString.uppercased() == OPOProtocol.serviceFE2C }) {
                return true
            }
        }

        // 4. Peripheral name or advertised local name check
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        return isAudioDeviceName(peripheralName) || isAudioDeviceName(advertisedName)
    }

    /// Parses battery telemetry directly from manufacturer advertisement payload (Company ID 0x072F)
    /// Example payload: 2F 07 14 10 06 3F 00 01 98 04 ED 6F 4B 2A 0F 84 29 C8 C8 BA 01
    /// Bytes 17..19 encode Left, Right, and Case battery levels.
    public static func parseAdvertisementBattery(_ advertisementData: [String: Any]) -> BatteryStatus? {
        guard let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, mfg.count >= 20 else {
            return nil
        }
        let bytes = [UInt8](mfg)
        guard bytes[0] == 0x2F && bytes[1] == 0x07 else { return nil }

        // Decode battery percentage from bytes 17, 18, 19
        func decodePct(_ raw: UInt8) -> Int? {
            // In Fast Pair and Oppo mfg: 0..100 is direct; 101..200 (like 0xC8 = 200) represents 2 * percentage (e.g. 200 / 2 = 100%)
            let intVal = Int(raw)
            if (0...100).contains(intVal) {
                return intVal
            } else if (101...200).contains(intVal) {
                return intVal / 2
            }
            let masked = Int(raw & 0x7F)
            if (0...100).contains(masked) {
                return masked
            }
            return nil
        }

        let left = decodePct(bytes[17])
        let right = decodePct(bytes[18])
        let c = decodePct(bytes[19])

        if left != nil || right != nil || c != nil {
            return BatteryStatus(left: left, right: right, case: c)
        }
        return nil
    }

    /// Parses the Bluetooth Classic MAC address (BD_ADDR) from manufacturer advertisement payload (Company ID 0x072F).
    /// Example payload: 2F 07 14 10 06 3F 00 01 98 04 ED 6F 4B 2A 0F 84 29 C8 C8 BA 01
    /// Bytes 10..15 encode the MAC address in little-endian order.
    /// Returns address formatted as "xx-xx-xx-xx-xx-xx" (lowercase).
    public static func parseAdvertisementAddress(_ advertisementData: [String: Any]) -> String? {
        guard let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, mfg.count >= 16 else {
            return nil
        }
        let bytes = [UInt8](mfg)
        guard bytes[0] == 0x2F && bytes[1] == 0x07 else { return nil }
        let macBytes = bytes[10...15].reversed()
        return macBytes.map { String(format: "%02x", $0) }.joined(separator: "-")
    }
}

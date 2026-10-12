import Foundation

// Buds Z2 ANC wire mapping:
// - 0x08: Max Noise Cancellation
// - 0x04: Normal Noise Cancellation
// - 0x02: Transparency
// - 0x01: Off
//
// Query responses (SUB=0x81) use the same wire bytes.
struct ANCWireMapping {
    static func toWire(_ mode: ANCMode) -> UInt8 {
        switch mode {
        case .on: return 0x08
        case .transparency: return 0x02
        case .off: return 0x01
        }
    }

    static func fromWire(_ byte: UInt8) -> ANCMode? {
        switch byte {
        case 0x08, 0x04, 0x10: return .on
        case 0x02: return .transparency
        case 0x01: return .off
        default: return nil
        }
    }
}

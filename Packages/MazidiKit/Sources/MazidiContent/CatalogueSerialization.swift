import Foundation

// ─────────────────────────────────────────────────────────────────────────────
//  Deterministic serialization (ADR-0010 §3): same value → identical bytes on
//  every run and toolchain, so the committed catalogue is reviewable and CI can
//  verify a regeneration matches. Sorted keys, pretty-printed, LF, trailing
//  newline, no escaped slashes.
// ─────────────────────────────────────────────────────────────────────────────

public enum CatalogueSerialization {
    public static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

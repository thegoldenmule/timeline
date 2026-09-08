import Foundation

/// The one JSON configuration every document, command, and event uses: sorted keys, unescaped
/// slashes, ISO-8601 dates with fractional seconds. Sorted keys plus id-keyed dictionaries make
/// the encoding canonical, so two equal projects encode to identical bytes.
public enum ProjectCodec {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(iso8601.format(date))
        }
        return e
    }()

    /// Like `encoder` but pretty-printed, for fixtures and debugging.
    public static let prettyEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        e.dateEncodingStrategy = encoder.dateEncodingStrategy
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            if let date = (try? iso8601.parse(s)) ?? (try? iso8601Plain.parse(s)) { return date }
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Bad ISO-8601 date: \(s)"))
        }
        return d
    }()

    static let iso8601 = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    static let iso8601Plain = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    public static func encode<T: Encodable>(_ value: T) throws -> Data { try encoder.encode(value) }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }
}

extension Project {
    /// Canonical bytes: sorted keys, no escaped slashes, compact.
    public func canonicalJSON() throws -> Data { try ProjectCodec.encoder.encode(self) }

    public static func fromJSON(_ data: Data) throws -> Project {
        try ProjectCodec.decoder.decode(Project.self, from: data)
    }
}

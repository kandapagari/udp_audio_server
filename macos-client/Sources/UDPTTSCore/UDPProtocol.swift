import Foundation

/// Swift mirror of `src/udp_tts/protocol.py`. Must stay byte-compatible.
///
/// Wire layout: 4-byte common header (magic "QT", version, type) + a
/// type-specific body. Multi-byte header fields are big-endian (network order);
/// audio PCM payloads are little-endian signed 16-bit (matching numpy `<i2`).
public enum UDPProtocol {
    public static let magic: [UInt8] = Array("QT".utf8)
    public static let version: UInt8 = 1
    public static let headerSize = 4
    /// Keep UDP payloads under a typical MTU to avoid IP fragmentation.
    public static let maxPayloadBytes = 1100

    public enum MsgType: UInt8 {
        case request = 1
        case header = 2
        case data = 3
        case end = 4
        case error = 5
    }

    public struct StreamHeader {
        public let streamID: UInt32
        public let sampleRate: UInt32
        public let channels: UInt16
        public let bitsPerSample: UInt16
        public let samplesPerFrame: UInt32
    }

    // MARK: Encode

    public static func buildRequest(streamID: UInt32, text: String,
                                    extras: [String: String] = [:]) -> Data {
        var payload: [String: Any] = ["stream_id": Int(streamID), "text": text]
        for (k, v) in extras { payload[k] = v }
        let json = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        var data = frame(.request)
        data.append(json)
        return data
    }

    // MARK: Decode

    /// Returns the message type and the body (bytes after the common header),
    /// or nil if the datagram is malformed or from another protocol.
    public static func parse(_ datagram: Data) -> (MsgType, Data)? {
        guard datagram.count >= headerSize else { return nil }
        let bytes = [UInt8](datagram)
        guard bytes[0] == magic[0], bytes[1] == magic[1], bytes[2] == version,
              let type = MsgType(rawValue: bytes[3]) else { return nil }
        return (type, datagram.subdata(in: headerSize..<datagram.count))
    }

    public static func parseHeader(_ body: Data) -> StreamHeader? {
        // !IIHHI = 4 + 4 + 2 + 2 + 4 = 16 bytes, big-endian
        guard body.count >= 16 else { return nil }
        let b = [UInt8](body)
        return StreamHeader(
            streamID: be32(b, 0),
            sampleRate: be32(b, 4),
            channels: be16(b, 8),
            bitsPerSample: be16(b, 10),
            samplesPerFrame: be32(b, 12)
        )
    }

    /// Parses a DATA body into (streamID, seq, pcm). PCM is little-endian int16.
    public static func parseData(_ body: Data) -> (UInt32, UInt32, Data)? {
        guard body.count >= 8 else { return nil }
        let b = [UInt8](body)
        let streamID = be32(b, 0)
        let seq = be32(b, 4)
        let pcm = body.subdata(in: 8..<body.count)
        return (streamID, seq, pcm)
    }

    public static func parseEnd(_ body: Data) -> (UInt32, UInt32)? {
        guard body.count >= 8 else { return nil }
        let b = [UInt8](body)
        return (be32(b, 0), be32(b, 4))
    }

    public static func parseError(_ body: Data) -> (UInt32, String)? {
        guard body.count >= 4 else { return nil }
        let b = [UInt8](body)
        let streamID = be32(b, 0)
        let msg = String(data: body.subdata(in: 4..<body.count), encoding: .utf8) ?? ""
        return (streamID, msg)
    }

    // MARK: Helpers

    private static func frame(_ type: MsgType) -> Data {
        Data([magic[0], magic[1], version, type.rawValue])
    }

    private static func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
        (UInt32(b[i]) << 24) | (UInt32(b[i + 1]) << 16)
            | (UInt32(b[i + 2]) << 8) | UInt32(b[i + 3])
    }

    private static func be16(_ b: [UInt8], _ i: Int) -> UInt16 {
        (UInt16(b[i]) << 8) | UInt16(b[i + 1])
    }
}

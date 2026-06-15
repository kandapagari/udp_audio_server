import XCTest
@testable import UDPTTSCore

final class JitterBufferTests: XCTestCase {
    let fb = 4  // bytes per frame for these tests

    private func frame(_ n: UInt8) -> Data { Data(repeating: n, count: 4) }

    func testReordersWithinWindow() {
        let jb = JitterBuffer(frameBytes: fb, reorderWindow: 8)
        for seq: UInt32 in [0, 2, 1, 3] { jb.push(seq: seq, pcm: frame(UInt8(seq))) }
        XCTAssertEqual(jb.readAvailable(maxBytes: 1000),
                       frame(0) + frame(1) + frame(2) + frame(3))
        XCTAssertEqual(jb.concealed, 0)
    }

    func testConcealsLostPacketWithSilence() {
        let jb = JitterBuffer(frameBytes: fb, reorderWindow: 2)
        for seq: UInt32 in [0, 2, 3, 4, 5] { jb.push(seq: seq, pcm: frame(UInt8(seq))) }
        let expected = frame(0) + Data(count: fb) + frame(2) + frame(3) + frame(4) + frame(5)
        XCTAssertEqual(jb.readAvailable(maxBytes: 1000), expected)
        XCTAssertEqual(jb.concealed, 1)
    }

    func testDropsPacketThatArrivesTooLate() {
        let jb = JitterBuffer(frameBytes: fb, reorderWindow: 2)
        for seq: UInt32 in [0, 1, 2, 3, 4] { jb.push(seq: seq, pcm: frame(UInt8(seq))) }
        _ = jb.readAvailable(maxBytes: 1000)
        jb.push(seq: 2, pcm: frame(2))  // too late
        XCTAssertEqual(jb.readAvailable(maxBytes: 1000), Data())
    }

    func testFlushEmitsTailWithSilence() {
        let jb = JitterBuffer(frameBytes: fb, reorderWindow: 100)
        jb.push(seq: 0, pcm: frame(0))
        jb.push(seq: 3, pcm: frame(3))
        jb.flushAndComplete()
        XCTAssertEqual(jb.readAvailable(maxBytes: 1000),
                       frame(0) + Data(count: fb) + Data(count: fb) + frame(3))
    }

    func testReadPadsOnUnderflow() {
        let jb = JitterBuffer(frameBytes: fb)
        jb.push(seq: 0, pcm: frame(7))
        let out = jb.read(count: 8)  // only 4 bytes available
        XCTAssertEqual(out, frame(7) + Data(count: 4))
    }
}

final class ProtocolTests: XCTestCase {
    /// Build a HEADER packet exactly as the Python server does and parse it back.
    func testHeaderRoundTrip() {
        var pkt = Data([0x51, 0x54, 1, UDPProtocol.MsgType.header.rawValue])  // "QT", v1, HEADER
        // !IIHHI big-endian: stream_id, sample_rate, channels, bits, samples/frame
        pkt.append(contentsOf: [0,0,0,7])            // stream_id = 7
        pkt.append(contentsOf: [0,0,0x5d,0xc0])      // 24000
        pkt.append(contentsOf: [0,1])                // channels = 1
        pkt.append(contentsOf: [0,16])               // bits = 16
        pkt.append(contentsOf: [0,0,2,0x26])         // samples/frame = 550
        guard let (type, body) = UDPProtocol.parse(pkt) else { return XCTFail("parse") }
        XCTAssertEqual(type, .header)
        let h = UDPProtocol.parseHeader(body)
        XCTAssertEqual(h?.streamID, 7)
        XCTAssertEqual(h?.sampleRate, 24000)
        XCTAssertEqual(h?.channels, 1)
        XCTAssertEqual(h?.bitsPerSample, 16)
        XCTAssertEqual(h?.samplesPerFrame, 550)
    }

    func testDataParse() {
        var pkt = Data([0x51, 0x54, 1, UDPProtocol.MsgType.data.rawValue])
        pkt.append(contentsOf: [0,0,0,7])     // stream_id
        pkt.append(contentsOf: [0,0,0,42])    // seq
        pkt.append(contentsOf: [0x01, 0x02, 0x03, 0x04])  // pcm
        guard let (_, body) = UDPProtocol.parse(pkt),
              let (sid, seq, pcm) = UDPProtocol.parseData(body) else { return XCTFail() }
        XCTAssertEqual(sid, 7)
        XCTAssertEqual(seq, 42)
        XCTAssertEqual(pcm, Data([0x01, 0x02, 0x03, 0x04]))
    }

    func testRejectsForeignDatagram() {
        XCTAssertNil(UDPProtocol.parse(Data()))
        XCTAssertNil(UDPProtocol.parse(Data([0x58, 0x58, 1, 3])))   // bad magic
        XCTAssertNil(UDPProtocol.parse(Data([0x51, 0x54, 9, 3])))   // bad version
    }

    func testRequestIsValidJSON() {
        let pkt = UDPProtocol.buildRequest(streamID: 5, text: "hi", extras: ["speaker": "Ryan"])
        guard let (type, body) = UDPProtocol.parse(pkt) else { return XCTFail() }
        XCTAssertEqual(type, .request)
        let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        XCTAssertEqual(obj?["text"] as? String, "hi")
        XCTAssertEqual(obj?["speaker"] as? String, "Ryan")
        XCTAssertEqual(obj?["stream_id"] as? Int, 5)
    }
}

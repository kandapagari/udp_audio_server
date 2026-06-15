import Foundation
import Network

/// Drives one request/stream over UDP using NWConnection.
///
/// Sends a REQUEST, then receives the HEADER / DATA* / END (or ERROR) datagrams.
/// Audio bytes flow into a `JitterBuffer`; lifecycle events are reported through
/// the callbacks, which are always invoked on the main queue.
public final class UDPStreamer {
    public enum StreamState: Equatable {
        case connecting
        case streaming
        case finished
        case failed(String)
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "udp-tts.streamer")
    private let streamID: UInt32
    private let text: String
    private let extras: [String: String]

    private var buffer: JitterBuffer?
    private var didStart = false

    public var onHeader: ((UDPProtocol.StreamHeader, JitterBuffer) -> Void)?
    public var onState: ((StreamState) -> Void)?
    public var onStats: ((Int, Int) -> Void)?  // received, concealed

    public init(host: String, port: UInt16, text: String, extras: [String: String]) {
        self.text = text
        self.extras = extras
        self.streamID = UInt32.random(in: 1...UInt32(Int32.max))
        let endpointPort = NWEndpoint.Port(rawValue: port) ?? 50007
        self.connection = NWConnection(host: NWEndpoint.Host(host),
                                       port: endpointPort, using: .udp)
    }

    public func start() {
        report(.connecting)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.sendRequest()
                self.receiveNext()
            case .failed(let error):
                self.report(.failed(error.localizedDescription))
            case .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    public func cancel() {
        connection.cancel()
    }

    // MARK: - private

    private func sendRequest() {
        let pkt = UDPProtocol.buildRequest(streamID: streamID, text: text, extras: extras)
        connection.send(content: pkt, completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.report(.failed("send failed: \(error.localizedDescription)"))
            }
        })
    }

    private func receiveNext() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self = self else { return }
            if let error = error {
                self.report(.failed("receive failed: \(error.localizedDescription)"))
                return
            }
            if let data = data, !data.isEmpty {
                self.handle(datagram: data)
            }
            // Re-arm unless the stream has ended.
            if self.buffer?.isComplete != true {
                self.receiveNext()
            }
        }
    }

    private func handle(datagram: Data) {
        guard let (type, body) = UDPProtocol.parse(datagram) else { return }
        switch type {
        case .header:
            guard let header = UDPProtocol.parseHeader(body),
                  header.streamID == streamID, !didStart else { return }
            didStart = true
            let frameBytes = Int(header.samplesPerFrame)
                * Int(header.channels) * Int(header.bitsPerSample) / 8
            let jb = JitterBuffer(frameBytes: frameBytes)
            self.buffer = jb
            DispatchQueue.main.async { [weak self] in
                self?.onHeader?(header, jb)
                self?.report(.streaming)
            }

        case .data:
            guard let (sid, seq, pcm) = UDPProtocol.parseData(body),
                  sid == streamID, let jb = buffer else { return }
            jb.push(seq: seq, pcm: pcm)
            reportStats(jb)

        case .end:
            guard let (sid, _) = UDPProtocol.parseEnd(body), sid == streamID,
                  let jb = buffer else { return }
            jb.flushAndComplete()
            reportStats(jb)
            report(.finished)

        case .error:
            guard let (sid, msg) = UDPProtocol.parseError(body), sid == streamID
            else { return }
            report(.failed("server error: \(msg)"))

        case .request:
            break  // never sent to the client
        }
    }

    private func reportStats(_ jb: JitterBuffer) {
        let received = jb.received, concealed = jb.concealed
        DispatchQueue.main.async { [weak self] in
            self?.onStats?(received, concealed)
        }
    }

    private func report(_ state: StreamState) {
        DispatchQueue.main.async { [weak self] in self?.onState?(state) }
    }
}

//
//  LocalStreamProxy.swift
//  Channels
//
//  Tiny localhost HTTP proxy for the live HLS playlists. libvlc (3.x) can't
//  send the custom auth headers (Content-Auth / Content-License / App …) that
//  the CDN requires on the .m3u8, so we serve the playlist from 127.0.0.1:
//  on each request we re-fetch the real playlist WITH the headers and return
//  it verbatim. The media segments are open (no auth) and have absolute URLs,
//  so VLC fetches those directly — no rewriting needed.
//

import Foundation
import Network

final class LocalStreamProxy: @unchecked Sendable {
    static let shared = LocalStreamProxy()

    private var listener: NWListener?
    private var port: UInt16 = 0
    private var starting = false
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []

    private var entries: [String: (url: URL, headers: [String: String])] = [:]
    private let lock = NSLock()
    private let session = URLSession(configuration: .ephemeral)
    private let queue = DispatchQueue(label: "LocalStreamProxy", attributes: .concurrent)

    private init() {}

    /// Register a live playlist and return a local URL a player can play.
    ///
    /// `preferLAN` addresses the playlist via the device's Wi-Fi IP instead of
    /// `127.0.0.1`. That's required for **AirPlay**: in external-playback mode the
    /// AirPlay receiver (e.g. Apple TV) fetches the HLS playlist itself and can't
    /// reach the phone's loopback. On-device playback keeps using loopback (no
    /// Local Network permission needed). Falls back to loopback if no Wi-Fi IP.
    func localURL(for url: URL, headers: [String: String], preferLAN: Bool = false) async -> URL? {
        await ensureReady()
        guard port != 0 else { return nil }
        let token = UUID().uuidString
        lock.lock(); entries[token] = (url, headers); lock.unlock()
        let host = (preferLAN ? Self.wifiIPv4Address() : nil) ?? "127.0.0.1"
        return URL(string: "http://\(host):\(port)/\(token).m3u8")
    }

    /// The device's Wi-Fi (en0) IPv4 address, if connected — reachable by other
    /// devices on the same network (the AirPlay receiver).
    static func wifiIPv4Address() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let flags = Int32(interface.ifa_flags)
            guard (flags & (IFF_UP | IFF_RUNNING | IFF_LOOPBACK)) == (IFF_UP | IFF_RUNNING),
                  interface.ifa_addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: interface.ifa_name) == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                        &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            address = String(cString: host)
        }
        return address
    }

    // MARK: - Listener lifecycle

    private func ensureReady() async {
        if port != 0 { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if port != 0 { lock.unlock(); cont.resume(); return }
            readyWaiters.append(cont)
            let shouldStart = !starting
            starting = true
            lock.unlock()
            if shouldStart { start() }
        }
    }

    private func start() {
        guard let listener = try? NWListener(using: .tcp) else { resumeWaiters(); return }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state, let p = listener.port?.rawValue {
                self.port = p
                self.resumeWaiters()
            } else if case .failed = state {
                self.resumeWaiters()
            }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        listener.start(queue: queue)
    }

    private func resumeWaiters() {
        lock.lock()
        let waiters = readyWaiters
        readyWaiters.removeAll()
        lock.unlock()
        waiters.forEach { $0.resume() }
    }

    // MARK: - Request handling

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if let headEnd = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(data: buf[..<headEnd.lowerBound], encoding: .utf8) ?? ""
                self.respond(conn, requestHead: head)
            } else if error == nil && !isComplete && buf.count < 65536 {
                self.receive(conn, buffer: buf)
            } else {
                conn.cancel()
            }
        }
    }

    private func respond(_ conn: NWConnection, requestHead: String) {
        guard let firstLine = requestHead.split(separator: "\r\n").first else { conn.cancel(); return }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { conn.cancel(); return }
        let path = String(parts[1]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let token = path.replacingOccurrences(of: ".m3u8", with: "")

        lock.lock(); let entry = entries[token]; lock.unlock()
        guard let entry else { send(conn, status: "404 Not Found", body: Data(), contentType: "text/plain"); return }

        var request = URLRequest(url: entry.url)
        request.timeoutInterval = 12
        entry.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        session.dataTask(with: request) { [weak self] data, response, _ in
            guard let self else { conn.cancel(); return }
            if let data, (response as? HTTPURLResponse)?.statusCode == 200 {
                self.send(conn, status: "200 OK", body: data, contentType: "application/vnd.apple.mpegurl")
            } else {
                self.send(conn, status: "502 Bad Gateway", body: Data(), contentType: "text/plain")
            }
        }.resume()
    }

    private func send(_ conn: NWConnection, status: String, body: Data, contentType: String) {
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Connection: close\r\n\r\n"
        var out = Data(header.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }
}

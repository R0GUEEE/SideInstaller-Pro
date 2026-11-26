import Foundation
import Network
import Combine

/// A tiny HTTP server inside the app, bound to loopback only, serving the
/// Telegram studio's generated source.
///
/// Why it exists: some clients want a *URL*, not a file. With this running, the
/// source is at `http://127.0.0.1:<port>/telegram-source.json` — reachable by
/// anything on the same iPhone that can open a socket, including SideStore and
/// AltStore added as sources. The document is rebuilt on every request from the
/// latest scan, so the URL is genuinely live rather than a snapshot.
///
/// **What it can't do:** read your joined channels. An `api_id`/`api_hash` pair
/// identifies an application to Telegram; it isn't a login. Reading a private or
/// preview-off channel needs an MTProto session belonging to your account, and
/// that client isn't in this build. So the server serves what the studio can
/// already produce — public previews, imported exports, plus each channel's own
/// direct `.ipa` links — and says so at `/`.
///
/// **It also stops when the app is suspended.** iOS doesn't keep a socket alive
/// in the background without a background mode this app doesn't have, so the
/// server runs while SideInstaller is in the foreground. Clients that fetch the
/// source while it's up keep their copy.
@MainActor
final class LocalSourceServer: ObservableObject {

    static let shared = LocalSourceServer()

    enum State: Equatable {
        case stopped
        case starting
        case running(port: UInt16)
        case failed(String)
    }

    @Published private(set) var state: State = .stopped
    @Published var port: UInt16 = 8123
    /// Requests served since it started, for the card's status line.
    @Published private(set) var served = 0
    @Published private(set) var lastRequest: Date?

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    /// The document last served, and when. Regenerating it writes a file, which
    /// shouldn't happen once per request — a page load fetches it and the HTML
    /// beside it.
    private var cachedDocument: (data: Data, at: Date)?
    private static let documentLifetime: TimeInterval = 5

    var url: URL? {
        guard case .running(let port) = state else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/telegram-source.json")
    }

    var indexURL: URL? {
        guard case .running(let port) = state else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/")
    }

    // MARK: - Lifecycle

    func start() {
        guard listener == nil else { return }
        // The port comes from Settings, so it can be moved off a busy one.
        let wanted = UInt16(clamping: AppSettings.shared.serverPort)
        if wanted > 0 { port = wanted }
        state = .starting
        do {
            let parameters = NWParameters.tcp
            // Loopback only: binding to 127.0.0.1 means nothing on the local
            // network can reach it. The port goes in the endpoint rather than
            // `NWListener(using:on:)`, which would listen on every interface.
            let requested = NWEndpoint.Port(rawValue: port) ?? 8123
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: requested)
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] newState in
                Task { @MainActor in
                    guard let self else { return }
                    switch newState {
                    case .ready:
                        let bound = listener.port?.rawValue ?? self.port
                        self.port = bound
                        self.state = .running(port: bound)
                        Engine.shared.log("Local source server listening on 127.0.0.1:\(bound).")
                    case .failed(let error):
                        self.state = .failed(L("Couldn't start the server: %@", error.localizedDescription))
                        self.stop()
                    default:
                        break
                    }
                }
            }
            self.listener = listener
            listener.start(queue: .global(qos: .userInitiated))
        } catch {
            state = .failed(L("Couldn't start the server: %@", error.localizedDescription))
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for (_, connection) in connections { connection.cancel() }
        connections.removeAll()
        state = .stopped
    }

    // MARK: - Requests

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.stateUpdateHandler = { [weak self] newState in
            if case .failed = newState {
                Task { @MainActor in
                    self?.connections[key] = nil
                    connection.cancel()
                }
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        receive(on: connection, buffer: Data())
    }

    /// Reads until the end of the request headers — that's all this needs, since
    /// every route is a GET.
    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
            [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var data = buffer
            if let chunk { data.append(chunk) }
            if let request = Self.request(from: data) {
                Task { @MainActor in self.respond(to: request, on: connection) }
                return
            }
            if isComplete || error != nil || data.count > 64 * 1024 {
                connection.cancel()
                Task { @MainActor in self.connections[ObjectIdentifier(connection)] = nil }
                return
            }
            self.receive(on: connection, buffer: data)
        }
    }

    private struct Request {
        let method: String
        let path: String
    }

    private static func request(from data: Data) -> Request? {
        // The blank line ends the headers.
        guard let text = String(data: data, encoding: .utf8),
              let range = text.range(of: "\r\n\r\n") ?? text.range(of: "\n\n") else { return nil }
        let head = text[..<range.lowerBound]
        let firstLine = head.split(separator: "\r\n").first ?? head.split(separator: "\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return Request(method: String(parts[0]), path: String(parts[1]))
    }

    private func respond(to request: Request, on connection: NWConnection) {
        defer {
            served += 1
            lastRequest = Date()
        }
        guard request.method == "GET" else {
            send(status: 405, type: "text/plain", body: Data("Only GET is served.".utf8), on: connection)
            return
        }
        let path = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"

        switch path {
        case "/", "/index.html":
            send(status: 200, type: "text/html; charset=utf-8",
                 body: Data(Self.indexPage().utf8), on: connection)
        case "/telegram-source.json", "/source.json":
            guard let data = sourceDocument() else {
                send(status: 503, type: "text/plain",
                     body: Data("No scan yet. Open SideInstaller › Sources › Telegram channels and scan."
                        .utf8), on: connection)
                return
            }
            send(status: 200, type: "application/json", body: data, on: connection)
        case "/analyze", "/analyze.html":
            send(status: 200, type: "text/html; charset=utf-8",
                 body: Data(Self.analyzePage().utf8), on: connection)
        case "/analyze.json":
            send(status: 200, type: "application/json",
                 body: Data(Self.analyzeJSON().utf8), on: connection)
        case "/health":
            let entries = TelegramStudio.shared.allEntries.count
            let body = #"{"status":"ok","apps":\#(entries),"channels":\#(TelegramStudio.shared.channels.count)}"#
            send(status: 200, type: "application/json", body: Data(body.utf8), on: connection)
        default:
            send(status: 404, type: "text/plain", body: Data("Not found.".utf8), on: connection)
        }
    }

    /// The generated document: rebuilt when the cached copy is a few seconds
    /// old, so a burst of requests doesn't rewrite it repeatedly.
    private func sourceDocument() -> Data? {
        if let cached = cachedDocument,
           Date().timeIntervalSince(cached.at) < Self.documentLifetime {
            return cached.data
        }
        guard let generated = TelegramStudio.shared.generateSource(),
              let data = try? Data(contentsOf: generated.url) else { return nil }
        cachedDocument = (data, Date())
        return data
    }

    private func send(status: Int, type: String, body: Data, on connection: NWConnection) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 503: reason = "Service Unavailable"
        default:  reason = "OK"
        }
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        header += "Content-Type: \(type)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Cache-Control: no-store\r\n"
        header += "Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
            Task { @MainActor in self.connections[ObjectIdentifier(connection)] = nil }
        })
    }

    // MARK: - The index

    /// Every channel the studio knows, its apps and their links — the page a
    /// browser or a webview can be pointed at.
    @MainActor
    private static func analyzePage() -> String {
        let studio = TelegramStudio.shared
        var sections: [String] = []
        for result in studio.results + studio.imports {
            let rows = result.entries.map { entry -> String in
                let version = entry.latest?.version ?? "—"
                let link = entry.latest?.url ?? ""
                let direct = entry.latest?.direct == true
                let size = entry.latest?.size.map {
                    ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
                } ?? "—"
                return "<tr><td>" + escape(entry.name) + "</td><td>" + escape(version)
                    + "</td><td>" + escape(size) + "</td><td><a href=\"" + escape(link) + "\">"
                    + (direct ? "download" : "open in Telegram") + "</a></td></tr>"
            }.joined()
            let header = result.error.map { " — " + escape($0) } ?? " · \(result.entries.count) apps"
            sections.append("<div class=\"card\"><h2>@" + escape(result.channel) + header
                + "</h2><table><tr><th>app</th><th>version</th><th>size</th><th></th></tr>"
                + rows + "</table></div>")
        }
        let body = sections.isEmpty
            ? "<div class=\"card\"><p>No scan yet. Open SideInstaller › Sources › Telegram channels and scan.</p></div>"
            : sections.joined()
        return page(title: "Telegram analysis", body: body)
    }

    /// The same information as JSON, for a client that wants to build its own UI.
    @MainActor
    private static func analyzeJSON() -> String {
        let studio = TelegramStudio.shared
        let channels: [[String: Any]] = (studio.results + studio.imports).map { result in
            [
                "channel": result.channel,
                "error": result.error ?? NSNull(),
                "apps": result.entries.map { entry -> [String: Any] in
                    [
                        "name": entry.name,
                        "version": entry.latest?.version ?? NSNull(),
                        "size": entry.latest?.size ?? NSNull(),
                        "url": entry.latest?.url ?? NSNull(),
                        "direct": entry.latest?.direct ?? false,
                    ]
                },
            ]
        }
        let document: [String: Any] = [
            "generated": ISO8601DateFormatter().string(from: Date()),
            "channels": channels,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: document,
                                                     options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func page(title: String, body: String) -> String {
        "<!doctype html><html><head><meta charset=\"utf-8\">"
        + "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
        + "<title>\(title)</title><style>"
        + "body{font:16px -apple-system,system-ui;margin:0;padding:24px;background:#0b0f1a;color:#e8edf7}"
        + "h1{font-size:22px;margin:0 0 8px} h2{font-size:16px;margin:0 0 8px}"
        + "p{color:#9aa7bd;margin:6px 0} a{color:#5aa2ff;text-decoration:none}"
        + ".card{background:#141a28;border:1px solid #22304a;border-radius:14px;padding:16px;"
        + "margin:14px 0;overflow-x:auto}"
        + "table{width:100%;border-collapse:collapse;font-size:14px}"
        + "th,td{text-align:left;padding:6px;border-top:1px solid #1d2740;color:#c8d3e6;"
        + "vertical-align:top;word-break:break-word}"
        + "th{color:#8296b3;font-weight:600;border-top:0}"
        + "</style></head><body><h1>\(title)</h1>\(body)</body></html>"
    }

    /// A page listing what the server is serving, and what it can't.
    @MainActor
    private static func indexPage() -> String {
        let studio = TelegramStudio.shared
        let entries = studio.allEntries
        let channels = studio.channels
        let rows = channels.map { channel in
            "<tr><td>@\(channel.handle)</td><td>\(channel.enabled ? "on" : "off")</td>" +
            "<td>\(channel.pages) page(s)</td></tr>"
        }.joined()
        let credentials = TelegramCredentials.shared.isConfigured
        let authNote = credentials
            ? "API credentials are saved, but a login session isn't implemented in this build: channels are read through their public previews and imported exports."
            : "No API credentials set. Channels are read through their public previews and imported exports."

        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>SideInstaller — Telegram source</title>
        <style>
          body{font:16px -apple-system,system-ui;margin:0;padding:24px;background:#0b0f1a;color:#e8edf7}
          h1{font-size:22px;margin:0 0 4px} p{color:#9aa7bd;margin:6px 0}
          code,a{font-family:ui-monospace,Menlo,monospace}
          .card{background:#141a28;border:1px solid #22304a;border-radius:14px;padding:16px;margin:14px 0}
          table{width:100%;border-collapse:collapse} td{padding:6px 4px;border-top:1px solid #1d2740;color:#c8d3e6}
          td:first-child{font-family:ui-monospace,Menlo,monospace}
          a{color:#5aa2ff;text-decoration:none}
        </style></head><body>
        <h1>Telegram source</h1>
        <p>Served by SideInstaller on this iPhone, loopback only.</p>
        <div class="card">
          <p><strong>\(entries.count)</strong> apps from <strong>\(channels.count)</strong> channels</p>
          <p><a href="/telegram-source.json">/telegram-source.json</a> — add this URL as a source</p>
          <p><a href="/health">/health</a> — JSON status</p>
          <p><a href="/analyze">/analyze</a> — what each channel yielded</p>
        </div>
        <div class="card"><table>
          <tr><td>channel</td><td>scan</td><td>depth</td></tr>
          \(rows)
        </table></div>
        <div class="card"><p>\(authNote)</p>
        <p>The server stops when SideInstaller leaves the foreground: iOS doesn't keep a socket alive in the background.</p></div>
        </body></html>
        """
    }
}

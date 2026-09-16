import Foundation
import Network

/// A loopback proxy that makes an Anthropic-compatible server take what Claude Code sends.
///
/// Claude Code 2.1.200 adds context mid-conversation as a `role: "system"` message inside
/// `messages`. Anthropic's API accepts it; vLLM's Anthropic endpoint — and so a LiteLLM proxy in
/// front of it — answers 400, in words Claude Code's own fallback does not recognise, so every
/// turn fails. The relay folds each such message into the neighbouring user turn as a
/// `<system-reminder>` block, which is exactly the shape Claude Code falls back to on its own
/// when a server *does* say it cannot take system messages.
///
/// It also gives Claude Desktop a loopback address: the desktop refuses a plain-HTTP gateway on
/// the network, but accepts `http://127.0.0.1`.
///
/// Everything else passes through untouched, and responses stream through as they arrive —
/// Claude Code only ever streams, so buffering a reply would be buffering the whole turn.
public final class CompatibilityRelay: @unchecked Sendable {
    public enum State: Equatable {
        case stopped
        case running
        case failed(String)
    }

    public let port: UInt16
    public let upstream: URL

    public var state: State {
        queue.sync { _state }
    }

    /// How many requests had system messages folded. Shown so the relay's work is visible.
    public var foldedRequests: Int {
        queue.sync { _folded }
    }

    private var _state: State = .stopped
    private var _folded = 0
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.irvcassio.ClaudeSwitch.relay")
    private let streams = StreamRouter()
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        // Idle time between bytes: a thinking model can be silent for a long while.
        config.timeoutIntervalForRequest = 900
        config.timeoutIntervalForResource = 6 * 3600
        config.httpMaximumConnectionsPerHost = 32
        return URLSession(configuration: config, delegate: streams, delegateQueue: nil)
    }()

    public init(port: UInt16, upstream: URL) {
        self.port = port
        self.upstream = upstream
    }

    public var clientURL: String { "http://127.0.0.1:\(port)" }

    public func start() throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw RelayError.invalidPort(port)
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Loopback only: the relay carries keys and must never be reachable from the network.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        let listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self._state = .running
            case .failed(let error): self._state = .failed(error.localizedDescription)
            case .cancelled: self._state = .stopped
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    /// Starts and waits until the listener is ready or has failed.
    public func startAndWait(timeout: TimeInterval = 3) throws {
        try start()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch state {
            case .running: return
            case .failed(let message): throw RelayError.listenFailed(message)
            case .stopped: Thread.sleep(forTimeInterval: 0.02)
            }
        }
        throw RelayError.listenFailed("timed out")
    }

    public func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            _state = .stopped
        }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPRequest.parse(buffer) {
            case .complete(let request):
                self.forward(request, to: connection)
            case .invalid(let reason):
                self.respondWithError(400, reason, on: connection)
            case .incomplete:
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
            }
        }
    }

    private func forward(_ request: HTTPRequest, to connection: NWConnection) {
        guard let url = URL(string: upstream.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                            + request.target) else {
            respondWithError(400, "Unusable request target \(request.target)", on: connection)
            return
        }
        var outbound = URLRequest(url: url)
        outbound.httpMethod = request.method
        for (name, value) in request.headers where !Self.hopByHop.contains(name.lowercased()) {
            outbound.addValue(value, forHTTPHeaderField: name)
        }
        // Compressed replies would reach the client decompressed with a stale header.
        outbound.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        var body = request.body
        if request.method == "POST", request.path.hasSuffix("/v1/messages") || request.path.hasSuffix("/v1/messages/count_tokens"),
           let folded = Self.foldSystemMessages(in: body) {
            body = folded
            _folded += 1
        }
        if !body.isEmpty { outbound.httpBody = body }

        let task = session.dataTask(with: outbound)
        streams.register(task: task, handler: ResponseWriter(connection: connection, queue: queue))
        task.resume()
    }

    private func respondWithError(_ status: Int, _ message: String, on connection: NWConnection) {
        ResponseWriter(connection: connection, queue: queue).fail(status: status, message: message)
    }

    static let hopByHop: Set<String> = [
        "host", "connection", "keep-alive", "proxy-connection", "transfer-encoding", "te",
        "trailer", "upgrade", "content-length", "accept-encoding",
    ]

    // MARK: - The fold

    /// Moves every `role: "system"` message in `messages` into a user turn, wrapped as a
    /// `<system-reminder>`. Returns nil when the body has none, so it is forwarded byte-for-byte.
    ///
    /// A system message joins the user turn before it; with none before it, the user turn after
    /// it; with neither, it becomes a user turn of its own. Adjacent user turns are then merged,
    /// because a server that rejects `system` usually insists on user/assistant alternation too.
    public static func foldSystemMessages(in body: Data) -> Data? {
        guard var root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let messages = root["messages"] as? [[String: Any]],
              messages.contains(where: { $0["role"] as? String == "system" })
        else { return nil }

        var out: [[String: Any]] = []
        var pending: [[String: Any]] = []  // reminders waiting for a user turn after them

        for message in messages {
            let role = message["role"] as? String
            if role == "system" {
                let reminder = reminderBlock(message["content"])
                if let last = out.last, last["role"] as? String == "user" {
                    out[out.count - 1]["content"] = blocks(last["content"]) + [reminder]
                } else {
                    pending.append(reminder)
                }
                continue
            }
            var message = message
            if role == "user", !pending.isEmpty {
                message["content"] = pending + blocks(message["content"])
                pending.removeAll()
            } else if !pending.isEmpty {
                out.append(["role": "user", "content": pending])
                pending.removeAll()
            }
            if role == "user", let last = out.last, last["role"] as? String == "user" {
                out[out.count - 1]["content"] = blocks(last["content"]) + blocks(message["content"])
            } else {
                out.append(message)
            }
        }
        if !pending.isEmpty {
            if let last = out.last, last["role"] as? String == "user" {
                out[out.count - 1]["content"] = blocks(last["content"]) + pending
            } else {
                out.append(["role": "user", "content": pending])
            }
        }

        root["messages"] = out
        return try? JSONSerialization.data(withJSONObject: root)
    }

    private static func blocks(_ content: Any?) -> [[String: Any]] {
        if let text = content as? String { return [["type": "text", "text": text]] }
        return content as? [[String: Any]] ?? []
    }

    private static func reminderBlock(_ content: Any?) -> [String: Any] {
        let text = blocks(content).compactMap { $0["text"] as? String }.joined(separator: "\n\n")
        return ["type": "text", "text": "<system-reminder>\n\(text)\n</system-reminder>"]
    }

    public enum RelayError: LocalizedError {
        case invalidPort(UInt16)
        case listenFailed(String)

        public var errorDescription: String? {
            switch self {
            case .invalidPort(let port): "Port \(port) cannot be used for the relay."
            case .listenFailed(let message): "The relay could not listen on 127.0.0.1: \(message)"
            }
        }
    }
}

// MARK: - HTTP request parsing

struct HTTPRequest {
    var method: String
    var target: String
    var headers: [(String, String)]
    var body: Data

    var path: String { String(target.split(separator: "?", maxSplits: 1).first ?? "") }

    enum ParseResult {
        case incomplete
        case invalid(String)
        case complete(HTTPRequest)
    }

    static func parse(_ data: Data) -> ParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = data.range(of: separator) else {
            return data.count > 64_000 ? .invalid("Request headers too large.") : .incomplete
        }
        guard let head = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            return .invalid("Request headers are not UTF-8.")
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .invalid("Malformed request line.") }

        var headers: [(String, String)] = []
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers.append((String(line[..<colon]).trimmingCharacters(in: .whitespaces),
                            String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
        }
        func header(_ name: String) -> String? {
            headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
        }

        let rest = data[headerEnd.upperBound...]
        var body = Data()
        if header("transfer-encoding")?.lowercased().contains("chunked") == true {
            guard let decoded = decodeChunked(Data(rest)) else { return .incomplete }
            body = decoded
        } else if let length = header("content-length").flatMap(Int.init) {
            guard rest.count >= length else { return .incomplete }
            body = Data(rest.prefix(length))
        }
        return .complete(HTTPRequest(method: String(requestLine[0]), target: String(requestLine[1]),
                                     headers: headers, body: body))
    }

    /// nil until the terminating zero-length chunk has arrived.
    static func decodeChunked(_ data: Data) -> Data? {
        var output = Data()
        var index = data.startIndex
        let crlf = Data("\r\n".utf8)
        while true {
            guard let lineEnd = data.range(of: crlf, in: index..<data.endIndex) else { return nil }
            let sizeText = String(decoding: data[index..<lineEnd.lowerBound], as: UTF8.self)
                .split(separator: ";").first.map(String.init) ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else { return nil }
            index = lineEnd.upperBound
            if size == 0 { return output }
            guard data.distance(from: index, to: data.endIndex) >= size + 2 else { return nil }
            let end = data.index(index, offsetBy: size)
            output.append(data[index..<end])
            index = data.index(end, offsetBy: 2)
        }
    }
}

// MARK: - Streaming the response back

/// Writes one upstream response to one client connection as it arrives, chunked, then closes.
final class ResponseWriter: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var headWritten = false

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func head(_ response: HTTPURLResponse) {
        queue.async { [self] in
            var text = "HTTP/1.1 \(response.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: response.statusCode).capitalized)\r\n"
            for (key, value) in response.allHeaderFields {
                guard let name = key as? String,
                      !["content-length", "transfer-encoding", "connection", "content-encoding"].contains(name.lowercased())
                else { continue }
                text += "\(name): \(value)\r\n"
            }
            text += "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
            headWritten = true
            connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
        }
    }

    func body(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [self] in
            var chunk = Data(String(data.count, radix: 16).utf8)
            chunk.append(Data("\r\n".utf8))
            chunk.append(data)
            chunk.append(Data("\r\n".utf8))
            connection.send(content: chunk, completion: .contentProcessed { _ in })
        }
    }

    func finish(error: Error?) {
        queue.async { [self] in
            guard headWritten else {
                fail(status: 502, message: "ClaudeSwitch relay could not reach the upstream server: "
                     + (error?.localizedDescription ?? "no response"))
                return
            }
            // A stream cut mid-way is closed without the terminating chunk, so the client sees
            // a dropped connection rather than a complete-looking reply.
            if error == nil {
                connection.send(content: Data("0\r\n\r\n".utf8), completion: .contentProcessed { [connection] _ in
                    connection.cancel()
                })
            } else {
                connection.cancel()
            }
        }
    }

    func fail(status: Int, message: String) {
        let payload: [String: Any] = ["type": "error", "error": ["type": "api_error", "message": message]]
        let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        var head = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status).capitalized)\r\n"
        head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { [connection] _ in connection.cancel() })
    }
}

/// Routes URLSession delegate callbacks to the writer for each task.
final class StreamRouter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var writers: [Int: ResponseWriter] = [:]
    private let lock = NSLock()

    func register(task: URLSessionTask, handler: ResponseWriter) {
        lock.withLock { writers[task.taskIdentifier] = handler }
    }

    private func writer(_ task: URLSessionTask) -> ResponseWriter? {
        lock.withLock { writers[task.taskIdentifier] }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse { writer(dataTask)?.head(http) }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        writer(dataTask)?.body(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let writer = lock.withLock { writers.removeValue(forKey: task.taskIdentifier) }
        writer?.finish(error: error)
    }

    // Redirects are the upstream's business; the client should see them.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

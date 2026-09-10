import Foundation
import Darwin

public struct HTTPRequest {
    public let method: String
    public let path: String
    public let query: [String: String]
    public let headers: [String: String]
    public let body: Data
    public let remoteAddress: String
    public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data(), remoteAddress: String = "127.0.0.1") {
        self.method = method; self.path = path; self.query = query
        self.headers = headers.reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value }
        self.body = body; self.remoteAddress = remoteAddress
    }
    public func json() throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: body) as? [String: Any] else { throw C2CError("Expected JSON object") }
        return value
    }
    public func form() -> [String: String] { Self.decodeForm(String(decoding: body, as: UTF8.self)) }
    public static func decodeForm(_ input: String) -> [String: String] {
        var result: [String: String] = [:]
        for field in input.split(separator: "&") {
            let parts = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func decode(_ value: Substring) -> String { String(value).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(value) }
            if let key = parts.first { result[decode(key)] = parts.count > 1 ? decode(parts[1]) : "" }
        }
        return result
    }
}
public struct HTTPResponse {
    public var status: Int
    public var headers: [String: String]
    public var body: Data
    public init(status: Int = 200, headers: [String: String] = [:], body: Data = Data()) { self.status = status; self.headers = headers.reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value }; self.body = body }
    public static func json(_ value: Any, status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
        var headers = headers; headers["content-type"] = "application/json; charset=utf-8"
        do { return HTTPResponse(status: status, headers: headers, body: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])) }
        catch { return HTTPResponse(status: 500, headers: headers, body: Data("{\"error\":\"serialization_failed\"}".utf8)) }
    }
    public static func html(_ value: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["content-type": "text/html; charset=utf-8", "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'"], body: Data(value.utf8))
    }
}

/// A bounded HTTP/1.1 server that only listens on IPv4 loopback. One request per connection.
public final class HTTPServer {
    public private(set) var port: Int = 0
    private var socketFD: Int32 = -1
    private let queue = DispatchQueue(label: "c2c.http.accept")
    private let clients = DispatchSemaphore(value: 32)
    private let lock = NSLock()
    public init() {}
    public func start(port preferred: Int = 48765, handler: @escaping (HTTPRequest) -> HTTPResponse) throws {
        guard (0...65535).contains(preferred) else { throw C2CError("Port must be 0...65535") }
        func bindSocket(_ port: Int) throws -> Int32 {
            let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw C2CError("Cannot create HTTP socket") }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout.size(ofValue: one)))
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(port).bigEndian; address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            if result != 0 { let code = errno; Darwin.close(fd); throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
            guard listen(fd, 64) == 0 else { Darwin.close(fd); throw C2CError("Cannot listen") }
            return fd
        }
        do { socketFD = try bindSocket(preferred) }
        catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(EADDRINUSE) && preferred != 0 { socketFD = try bindSocket(0) }
        var address = sockaddr_in(); var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &size) } }
        port = Int(UInt16(bigEndian: address.sin_port))
        let listener = socketFD
        queue.async { [weak self] in
            guard let self else { return }
            while true {
                let fd = Darwin.accept(listener, nil, nil)
                if fd < 0 { if errno == EINTR { continue }; break }
                _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
                if self.clients.wait(timeout: .now()) != .success { Darwin.close(fd); continue }
                DispatchQueue.global().async {
                    defer { Darwin.close(fd); self.clients.signal() }
                    var limit = timeval(tv_sec: 15, tv_usec: 0)
                    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout.size(ofValue: limit)))
                    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout.size(ofValue: limit)))
                    var one: Int32 = 1
                    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
                    do { Self.send(handler(try Self.read(fd)), to: fd) }
                    catch { Self.send(.json(["error": "bad_request"], status: 400), to: fd) }
                }
            }
        }
    }
    public func stop() {
        lock.lock(); defer { lock.unlock() }
        if socketFD >= 0 { shutdown(socketFD, SHUT_RDWR); Darwin.close(socketFD); socketFD = -1 }
    }
    deinit { stop() }
    private static func read(_ fd: Int32) throws -> HTTPRequest {
        var buffer = Data(); let boundary = Data("\r\n\r\n".utf8); let maxBody = 8 * 1024 * 1024
        let deadline = Date().addingTimeInterval(20)
        func receive() throws {
            guard Date() < deadline else { throw C2CError("Request timed out") }
            var bytes = [UInt8](repeating: 0, count: 16384)
            let n = recv(fd, &bytes, bytes.count, 0)
            guard n > 0 else { throw C2CError("Incomplete request") }
            buffer.append(contentsOf: bytes.prefix(n))
            guard buffer.count <= maxBody + 65536 else { throw C2CError("Request too large") }
        }
        while buffer.range(of: boundary) == nil { guard buffer.count <= 32768 else { throw C2CError("Headers too large") }; try receive() }
        let split = buffer.range(of: boundary)!
        guard split.lowerBound <= 32768, let headerText = String(data: buffer[..<split.lowerBound], encoding: .utf8) else { throw C2CError("Invalid headers") }
        let lines = headerText.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, first[1].hasPrefix("/"), ["HTTP/1.1", "HTTP/1.0"].contains(String(first[2])) else { throw C2CError("Invalid request line") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { throw C2CError("Invalid header") }
            let key = String(line[..<colon]).lowercased()
            guard !key.isEmpty, key.range(of: "^[a-z0-9!#$%&'*+.^_`|~-]+$", options: .regularExpression) != nil, headers[key] == nil else { throw C2CError("Duplicate or invalid header") }
            headers[key] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        buffer = Data(buffer[split.upperBound...])
        var body = Data()
        if let transfer = headers["transfer-encoding"] {
            guard transfer.lowercased() == "chunked", headers["content-length"] == nil else { throw C2CError("Ambiguous body framing") }
            while true {
                while buffer.range(of: Data("\r\n".utf8)) == nil { guard buffer.count < 1024 else { throw C2CError("Bad chunk") }; try receive() }
                let lineEnd = buffer.range(of: Data("\r\n".utf8))!
                let raw = String(decoding: buffer[..<lineEnd.lowerBound], as: UTF8.self).split(separator: ";", omittingEmptySubsequences: false)[0]
                guard !raw.isEmpty, raw.allSatisfy({ $0.isHexDigit }), let count = Int(raw, radix: 16), count >= 0, count <= maxBody - body.count else { throw C2CError("Bad chunk size") }
                buffer = Data(buffer[lineEnd.upperBound...])
                if count == 0 { break }
                while buffer.count < count + 2 { try receive() }
                guard buffer[count] == 13, buffer[count + 1] == 10 else { throw C2CError("Bad chunk terminator") }
                body.append(buffer.prefix(count)); buffer = Data(buffer.dropFirst(count + 2))
            }
        } else {
            let raw = headers["content-length"] ?? "0"
            guard raw.range(of: "^[0-9]+$", options: .regularExpression) != nil, let count = Int(raw), count <= maxBody else { throw C2CError("Invalid content length") }
            if headers["expect"]?.lowercased() == "100-continue" { let interim = Array("HTTP/1.1 100 Continue\r\n\r\n".utf8); _ = interim.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) } }
            while buffer.count < count { try receive() }
            body = buffer.prefix(count)
        }
        let target = String(first[1]).split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        return HTTPRequest(method: String(first[0]), path: String(target[0]), query: target.count > 1 ? HTTPRequest.decodeForm(String(target[1])) : [:], headers: headers, body: body)
    }
    private static func send(_ response: HTTPResponse, to fd: Int32) {
        let reason = [200: "OK", 201: "Created", 202: "Accepted", 204: "No Content", 302: "Found", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 429: "Too Many Requests", 500: "Internal Server Error"][response.status] ?? "Response"
        var headers = response.headers.reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value }
        headers["content-length"] = String(response.body.count); headers["connection"] = "close"
        headers["cache-control"] = "no-store"; headers["x-content-type-options"] = "nosniff"
        var output = "HTTP/1.1 \(response.status) \(reason)\r\n"
        for (key, value) in headers where !key.contains("\r") && !key.contains("\n") && !value.contains("\r") && !value.contains("\n") { output += "\(key): \(value)\r\n" }
        var data = Data((output + "\r\n").utf8); data.append(response.body)
        data.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let n = Darwin.send(fd, bytes.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
                if n <= 0 { break }; sent += n
            }
        }
    }
}

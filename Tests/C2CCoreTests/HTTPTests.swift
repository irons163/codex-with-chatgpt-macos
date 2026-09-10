import XCTest
import Darwin
@testable import C2CCore

final class HTTPTests: XCTestCase {
    private func exchange(_ message: String, port: Int) throws -> String {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw C2CError("socket") }
        defer { Darwin.close(fd) }
        var time = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout.size(ofValue: time)))
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_port = UInt16(port).bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard connected == 0 else { throw C2CError("connect") }
        let data = Data(message.utf8)
        _ = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        var output = Data(); var bytes = [UInt8](repeating: 0, count: 8192)
        while true { let n = recv(fd, &bytes, bytes.count, 0); if n <= 0 { break }; output.append(contentsOf: bytes.prefix(n)) }
        return String(decoding: output, as: UTF8.self)
    }
    func testBodyAndChunkedRequest() throws {
        let server = HTTPServer(); try server.start(port: 0) { request in .json(["body": String(decoding: request.body, as: UTF8.self), "query": request.query]) }; defer { server.stop() }
        let normal = try exchange("POST /echo?q=a%2Bb HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\nhello", port: server.port)
        XCTAssertTrue(normal.contains("200 OK")); XCTAssertTrue(normal.contains("hello")); XCTAssertTrue(normal.contains("a+b"))
        let chunked = try exchange("POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nhe\r\n3\r\nllo\r\n0\r\n\r\n", port: server.port)
        XCTAssertTrue(chunked.contains("200 OK")); XCTAssertTrue(chunked.contains("hello"))
    }
    func testMalformedRequestsNeverReachHandler() throws {
        let server = HTTPServer(); try server.start(port: 0) { _ in XCTFail("Malformed request reached handler"); return HTTPResponse() }; defer { server.stop() }
        for raw in [
            "POST / HTTP/1.1\r\nContent-Length: 1\r\ncontent-length: 2\r\n\r\nxx",
            "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\nContent-Length: 0\r\n\r\n0\r\n\r\n",
            "POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n",
            "POST / HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n",
            "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n\r\n",
            "POST http://example.com HTTP/1.1\r\n\r\n"
        ] { XCTAssertTrue(try exchange(raw, port: server.port).contains("400 Bad Request"), raw) }
    }
    func testPreferredPortCollisionUsesEphemeralPort() throws {
        let first = HTTPServer(); try first.start(port: 0) { _ in .json(["first": true]) }; defer { first.stop() }
        let second = HTTPServer(); try second.start(port: first.port) { _ in .json(["second": true]) }; defer { second.stop() }
        XCTAssertNotEqual(first.port, second.port)
        XCTAssertTrue(try exchange("GET / HTTP/1.1\r\n\r\n", port: second.port).contains("second"))
    }
    func testFormDecodingPreservesEncodedPlusAndEquals() {
        XCTAssertEqual(HTTPRequest.decodeForm("a=hello+world&b=%2B%3D&empty="), ["a": "hello world", "b": "+=", "empty": ""])
    }
}

import XCTest
@testable import C2CCore

final class ExecutionTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { for root in roots { try? FileManager.default.removeItem(at: root) } }
    private func store() throws -> (ExecutionStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("c2c-execution-\(UUID().uuidString)"); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); roots.append(root)
        return (ExecutionStore(workspaceID: "abc123", stateDirectory: root), root)
    }

    func testRecordsAllowedOutputAndRedactsSecrets() throws {
        let (store, _) = try store()
        let record = try store.record(["taskId": "task-1", "iteration": 2, "changedFiles": ["a.swift"], "tests": "2 passed", "exitStatus": "ok", "command": "swift test", "output": "Authorization: Bearer c2c_at_abcdefghijklmnopqrstuv\nwrote /Users/alice/project/a.swift", "exitCode": 0])
        XCTAssertEqual(record["outputAvailable"] as? Bool, true)
        guard let id = record["outputId"] as? Int else { return XCTFail("missing output id") }
        switch store.readOutput(id: id) {
        case .failure: XCTFail("expected readable output")
        case .success(let value): XCTAssertFalse(value.1.contains("c2c_at_")); XCTAssertTrue(value.1.contains("[REDACTED]")); XCTAssertTrue(value.1.contains("/Users/[user]"))
        }
        XCTAssertEqual(store.latestRecord()?["taskId"] as? String, "task-1")
    }

    func testPrivateKeysAndCommandsOutsideAllowlistAreRestricted() throws {
        let (store, _) = try store()
        let privateKey = try store.record(["taskId": "key", "iteration": 0, "changedFiles": 0, "exitStatus": "failed", "command": "swift test", "output": "-----BEGIN RSA PRIVATE KEY-----\nsecret"])
        let disallowed = try store.record(["taskId": "cat", "iteration": 1, "changedFiles": 0, "exitStatus": "ok", "command": "cat .env", "output": "TOPSECRET"])
        for record in [privateKey, disallowed] {
            XCTAssertEqual(record["outputAvailable"] as? Bool, false)
            switch store.readOutput(id: record["outputId"] as! Int) { case .failure(.restricted): break; default: XCTFail("restricted body became readable") }
        }
        XCTAssertTrue(ExecutionStore.isAllowedCommand("pnpm run lint")); XCTAssertFalse(ExecutionStore.isAllowedCommand("swift test; cat .env")); XCTAssertFalse(ExecutionStore.isAllowedCommand("bash -c test"))
    }

    func testInvalidPersistedRecordsAreSkippedAndFilesArePrivate() throws {
        let (store, root) = try store(); _ = try store.record(["taskId": "valid", "iteration": 1, "changedFiles": 0, "tests": "ok", "exitStatus": "ok"])
        let file = root.appendingPathComponent("executions/abc123.jsonl"); let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: Data("{\"taskId\":\"invalid\",\"iteration\":null}\n".utf8)); try handle.close()
        XCTAssertEqual(store.readRecords(limit: 1).first?["taskId"] as? String, "valid")
        let permissions = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions.map { $0 & 0o777 }, 0o600)
    }

    func testConcurrentWritersReceiveUniqueOutputIDs() throws {
        let (_, root) = try store(); let group = DispatchGroup(), queue = DispatchQueue(label: "execution-writers", attributes: .concurrent)
        let lock = NSLock(); var failures: [Error] = []
        for index in 0..<20 {
            group.enter(); queue.async {
                defer { group.leave() }
                do { _ = try ExecutionStore(workspaceID: "abc123", stateDirectory: root).record(["taskId": "t\(index)", "iteration": index, "changedFiles": 0, "exitStatus": "ok", "command": "swift test", "output": "ok \(index)"]) }
                catch { lock.lock(); failures.append(error); lock.unlock() }
            }
        }
        group.wait(); XCTAssertTrue(failures.isEmpty)
        let final = ExecutionStore(workspaceID: "abc123", stateDirectory: root)
        XCTAssertEqual(final.readRecords(limit: 30).count, 20)
        let ids = final.listOutputs(limit: 30).compactMap { $0["id"] as? Int }
        XCTAssertEqual(Set(ids).count, 20); XCTAssertEqual(ids.sorted(), Array(1...20))
    }
}

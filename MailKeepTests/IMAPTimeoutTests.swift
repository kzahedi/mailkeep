import XCTest
import Network
@testable import MailKeep

final class IMAPTimeoutTests: XCTestCase {
    /// A TCP listener that accepts connections and never sends a byte —
    /// simulates a dead/black-holed IMAP server.
    private var listener: NWListener!
    private var port: UInt16 = 0

    override func setUp() async throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { conn in conn.start(queue: .global()) }
        listener.start(queue: .global())
        for _ in 0..<100 {   // wait for the port assignment
            if let p = listener.port?.rawValue, p != 0 { port = p; break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotEqual(port, 0, "listener never got a port")
    }

    override func tearDown() async throws {
        listener.cancel()
    }

    private func silentServerAccount() -> EmailAccount {
        EmailAccount(email: "timeout@test.local", imapServer: "127.0.0.1",
                     port: Int(port), useSSL: false)
    }

    func testReadResponseTimesOutAgainstSilentServer() async throws {
        let service = IMAPService(account: silentServerAccount())
        try await service.connect()
        let start = Date()
        // Race the read against a test-side deadline so a regression can
        // never hang the suite: the read must LOSE by throwing first.
        // The deadline (30s) is a generous multiple of the 2s watchdog so the
        // assertion is robust to scheduler jitter on loaded CI/dev machines —
        // the watchdog has been observed to fire exactly on schedule
        // (relative to its own clock) even when overall wall-clock hop
        // latency is inflated under heavy host load.
        let result = await withTaskGroup(of: String.self) { group in
            group.addTask {
                do { _ = try await service.readResponse(timeout: 2); return "returned" }
                catch { return "threw" }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                return "test-deadline"
            }
            let first = await group.next()!
            group.cancelAll()
            return first
        }
        XCTAssertEqual(result, "threw", "read against a silent server must throw via watchdog, not hang")
        XCTAssertLessThan(Date().timeIntervalSince(start), 25, "must fail well before the test's own 30s deadline")
        await service.disconnect()
    }

    func testConnectTimesOutAgainstUnroutableHost() async throws {
        // 10.255.255.1 is unroutable → connect hangs without a watchdog.
        let account = EmailAccount(email: "t@test.local", imapServer: "10.255.255.1",
                                   port: 993, useSSL: false)
        let service = IMAPService(account: account, connectTimeout: 3)
        let start = Date()
        // Deadline is a generous multiple of the 3s connect watchdog — see
        // comment in testReadResponseTimesOutAgainstSilentServer for why the
        // margin is wide (scheduler jitter under host load, not the watchdog
        // itself, which fires exactly on schedule).
        let result = await withTaskGroup(of: String.self) { group in
            group.addTask {
                do { try await service.connect(); return "connected" }
                catch { return "threw" }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 45_000_000_000)
                return "test-deadline"
            }
            let first = await group.next()!
            group.cancelAll()
            return first
        }
        XCTAssertEqual(result, "threw")
        XCTAssertLessThan(Date().timeIntervalSince(start), 40)
        await service.disconnect()
    }
}

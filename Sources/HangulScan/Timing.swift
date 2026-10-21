import Foundation

/// HS_TIMING=1 환경 변수가 있을 때만 단계별 소요 시간을 출력
enum Timing {
    static let enabled = ProcessInfo.processInfo.environment["HS_TIMING"] != nil
    @discardableResult
    static func measure<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
        guard enabled else { return try body() }
        let t = Date()
        let r = try body()
        print(String(format: "    ⏱ %@ %.2f초", label, Date().timeIntervalSince(t)))
        return r
    }
}

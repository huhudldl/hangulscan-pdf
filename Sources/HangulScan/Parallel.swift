import Foundation

enum Parallel {
    /// 동시에 처리할 페이지 수 (고해상도 이미지 메모리를 고려해 최대 4)
    static var workerCount: Int {
        if let v = ProcessInfo.processInfo.environment["HS_WORKERS"], let n = Int(v) { return max(1, n) }   // 테스트용
        return max(1, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))
    }

    /// 0..<count 를 여러 작업자가 나눠 처리하고 결과는 원래 순서대로 돌려준다.
    /// body의 두 번째 인자는 작업자 번호(작업자별 자원을 따로 쓸 때 사용).
    static func map<T>(_ count: Int, workers: Int = workerCount,
                       _ body: (_ index: Int, _ worker: Int) throws -> T) throws -> [T] {
        guard count > 0 else { return [] }
        var results = [Result<T, Error>?](repeating: nil, count: count)
        let lock = NSLock()
        var next = 0
        DispatchQueue.concurrentPerform(iterations: min(workers, count)) { w in
            while true {
                lock.lock(); let i = next; next += 1; lock.unlock()
                if i >= count { break }
                // 한 쪽이 끝날 때마다 고해상도 임시 이미지를 바로 해제
                let r = autoreleasepool { Result { try body(i, w) } }
                lock.lock(); results[i] = r; lock.unlock()
            }
        }
        return try results.map { try $0!.get() }
    }
}

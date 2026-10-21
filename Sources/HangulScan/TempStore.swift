import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// 스캔 이미지·중간 결과를 메모리 대신 디스크 임시 폴더에 둔다.
/// 페이지가 1000쪽이 넘어도 메모리 사용량이 늘지 않게 하기 위함. 앱 종료 시 삭제.
enum TempStore {
    static let root = FileManager.default.temporaryDirectory.appendingPathComponent("HangulScan", isDirectory: true)
    static let session: URL = {
        // 이전 실행에서 남은 임시 파일 정리
        try? FileManager.default.removeItem(at: root)
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func newURL(_ ext: String) -> URL {
        session.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    }

    static func cleanUp() { try? FileManager.default.removeItem(at: session) }

    /// JPEG으로 저장. PDF에 넣을 때 다시 압축하지 않고 그대로 들어간다.
    @discardableResult
    static func saveJPEG(_ image: CGImage, quality: CGFloat = 0.85, to url: URL = newURL("jpg")) -> URL? {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? url : nil
    }

    static func saveJPEG(_ image: CIImage, quality: CGFloat = 0.92) -> URL? {
        guard let cg = ImageProcessor.cgImage(image) else { return nil }
        return saveJPEG(cg, quality: quality)
    }

    static func loadImage(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// 화면 표시용 작은 미리보기 (긴 변 maxPixel)
    static func thumbnail(_ url: URL, maxPixel: Int = 420) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    static func pixelSize(_ url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: w, height: h)
    }
}

enum MemoryBudget {
    /// 해상도와 Mac 메모리 크기에 맞춘 동시 처리 쪽수.
    /// 실측: A4 300dpi 한 쪽 처리에 약 0.2~0.25GB, 해상도 제곱에 비례해 늘어남.
    /// 전체 메모리의 15% 안에서만 동시에 처리 → 8GB Mac에서 600dpi면 1쪽씩.
    static func workers(forDPI dpi: Double) -> Int {
        let perPage = 0.25e9 * pow(dpi / 300, 2)
        let budget = Double(ProcessInfo.processInfo.physicalMemory) * 0.15
        return max(1, min(Parallel.workerCount, Int(budget / perPage)))
    }
}

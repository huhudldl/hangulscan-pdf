import Foundation
import PDFKit

/// 페이지에 '파일 안에 실제로 들어 있는' 텍스트가 있는지 검사한다.
/// macOS는 화면에 띄운 이미지 PDF에 자동 OCR(라이브 텍스트)을 덧붙여 page.string이 채워지기도 하므로,
/// PDF 내용 스트림의 글자 그리기 명령(Tj, TJ, ', ")을 직접 세어 판별한다.
enum PDFTextProbe {
    private final class Counter {
        var count = 0
        var invisible = 0          // 보이지 않게 그린 글자(OCR 텍스트 층, Tr 3)
        var depth = 0
        var mode = 0               // 현재 글자 그리기 방식(Tr)
        var stack: [Int] = []      // q/Q 그래픽 상태 저장
    }

    enum Kind { case none, ocrLayerOnly, visibleText }

    static func hasText(_ page: PDFPage) -> Bool { kind(page) != .none }

    /// 글자 없음 / 보이지 않는 OCR 글자만 있음 / 눈에 보이는 진짜 글자가 있음
    static func kind(_ page: PDFPage) -> Kind {
        guard let ref = page.pageRef else { return .none }
        let counter = Counter()
        scan(CGPDFContentStreamCreateWithPage(ref), counter)
        if counter.count == 0 { return .none }
        return counter.invisible == counter.count ? .ocrLayerOnly : .visibleText
    }

    private static func scan(_ stream: CGPDFContentStreamRef, _ counter: Counter) {
        guard counter.depth < 6, let table = CGPDFOperatorTableCreate() else { return }
        let textOp: CGPDFOperatorCallback = { _, info in
            guard let info else { return }
            let c = Unmanaged<Counter>.fromOpaque(info).takeUnretainedValue()
            c.count += 1
            if c.mode == 3 { c.invisible += 1 }
        }
        for op in ["Tj", "TJ", "'", "\""] { CGPDFOperatorTableSetCallback(table, op, textOp) }
        CGPDFOperatorTableSetCallback(table, "Tr") { scanner, info in
            guard let info else { return }
            var v: CGPDFInteger = 0
            if CGPDFScannerPopInteger(scanner, &v) { Unmanaged<Counter>.fromOpaque(info).takeUnretainedValue().mode = Int(v) }
        }
        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            guard let info else { return }
            let c = Unmanaged<Counter>.fromOpaque(info).takeUnretainedValue(); c.stack.append(c.mode)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            guard let info else { return }
            let c = Unmanaged<Counter>.fromOpaque(info).takeUnretainedValue(); c.mode = c.stack.popLast() ?? 0
        }
        // 폼 XObject 안의 글자도 확인 (Do 명령)
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            guard let info else { return }
            let counter = Unmanaged<Counter>.fromOpaque(info).takeUnretainedValue()
            var namePtr: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &namePtr), let namePtr else { return }
            let cs = CGPDFScannerGetContentStream(scanner)
            guard let obj = CGPDFContentStreamGetResource(cs, "XObject", namePtr) else { return }
            var xstream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(obj, .stream, &xstream), let xstream,
                  let dict = CGPDFStreamGetDictionary(xstream) else { return }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dict, "Subtype", &subtype), let subtype,
                  String(cString: subtype) == "Form" else { return }
            var res: CGPDFDictionaryRef?
            _ = CGPDFDictionaryGetDictionary(dict, "Resources", &res)
            let inner = CGPDFContentStreamCreateWithStream(xstream, res ?? dict, cs)
            counter.depth += 1
            PDFTextProbe.scan(inner, counter)
            counter.depth -= 1
        }
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(counter).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFOperatorTableRelease(table)
    }
}

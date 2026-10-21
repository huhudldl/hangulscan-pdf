import SwiftUI
import PDFKit

/// 주석 도구 종류
enum AnnotTool: String, CaseIterable, Identifiable {
    case select, highlight, underline, strike, note, text, pen, rect, oval, arrow, eraser, signature
    var id: String { rawValue }
    var label: String {
        switch self {
        case .select: return "선택"
        case .highlight: return "형광펜"
        case .underline: return "밑줄"
        case .strike: return "취소선"
        case .note: return "메모"
        case .text: return "글상자"
        case .pen: return "펜"
        case .rect: return "사각형"
        case .oval: return "원"
        case .arrow: return "화살표"
        case .eraser: return "지우개"
        case .signature: return "서명"
        }
    }
    var icon: String {
        switch self {
        case .select: return "cursorarrow"
        case .highlight: return "highlighter"
        case .underline: return "underline"
        case .strike: return "strikethrough"
        case .note: return "note.text"
        case .text: return "character.textbox"
        case .pen: return "pencil.tip"
        case .rect: return "rectangle"
        case .oval: return "circle"
        case .arrow: return "arrow.up.right"
        case .eraser: return "eraser"
        case .signature: return "signature"
        }
    }
    var help: String {
        switch self {
        case .highlight, .underline, .strike: return "\(label): 글을 드래그하면 바로 적용"
        case .note: return "메모: 문서를 클릭한 자리에 메모 붙이기"
        case .text: return "글상자: 클릭한 자리에 글 쓰기"
        case .pen: return "펜: 끌어서 손글씨·밑줄 그리기"
        case .rect, .oval, .arrow: return "\(label): 끌어서 그리기"
        case .eraser: return "지우개: 지울 주석을 클릭"
        case .signature: return "서명: 클릭한 자리에 내 서명 넣기"
        case .select: return "선택: 글 선택·링크 누르기"
        }
    }
    /// 글 선택으로 동작하는 도구
    var isMarkup: Bool { self == .highlight || self == .underline || self == .strike }
}

/// 주석 도구를 지원하는 PDF 보기
final class AnnotatingPDFView: PDFView {
    var tool: AnnotTool = .select
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 2
    /// 주석 추가·삭제를 모델에 알림 (되돌리기·편집됨 표시)
    var onAdd: ((PDFAnnotation, PDFPage) -> Void)?
    var onRemove: ((PDFAnnotation, PDFPage) -> Void)?
    var onMarkup: (() -> Void)?
    var askText: ((String, String) -> String?)?
    var signature: (() -> [[CGPoint]]?)?

    private var startPoint: CGPoint?
    private var drawPage: PDFPage?
    private var preview: PDFAnnotation?
    private var inkPoints: [CGPoint] = []

    private var drawingTool: Bool { [.pen, .rect, .oval, .arrow].contains(tool) }

    override func mouseDown(with event: NSEvent) {
        guard tool != .select, !tool.isMarkup else { return super.mouseDown(with: event) }
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: true) else { return }
        let p = convert(viewPoint, to: page)
        switch tool {
        case .note:
            guard let text = askText?("메모", "메모 내용을 입력하세요"), !text.isEmpty else { return }
            let a = PDFAnnotation(bounds: CGRect(x: p.x - 10, y: p.y - 10, width: 22, height: 22), forType: .text, withProperties: nil)
            a.contents = text
            a.color = color
            add(a, page)
        case .text:
            guard let text = askText?("글상자", "문서에 쓸 글을 입력하세요"), !text.isEmpty else { return }
            let font = NSFont.systemFont(ofSize: 14)
            let size = (text as NSString).boundingRect(with: CGSize(width: 320, height: 2000), options: [.usesLineFragmentOrigin],
                                                       attributes: [.font: font]).size
            let a = PDFAnnotation(bounds: CGRect(x: p.x, y: p.y - size.height - 8, width: size.width + 14, height: size.height + 10),
                                  forType: .freeText, withProperties: nil)
            a.contents = text
            a.font = font
            a.fontColor = color
            a.color = .clear
            add(a, page)
        case .eraser:
            if let a = page.annotation(at: p), a.type != "Link" {
                page.removeAnnotation(a)
                onRemove?(a, page)
            }
        case .signature:
            guard let strokes = signature?(), !strokes.isEmpty else { return }
            placeSignature(strokes, at: p, on: page)
        default:
            startPoint = p
            drawPage = page
            inkPoints = [p]
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard drawingTool, let start = startPoint, let page = drawPage else { return super.mouseDragged(with: event) }
        let p = convert(convert(event.locationInWindow, from: nil), to: page)
        if let old = preview { page.removeAnnotation(old) }
        let a: PDFAnnotation?
        switch tool {
        case .pen:
            inkPoints.append(p)
            a = ink([inkPoints])
        case .rect, .oval:
            let r = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
            let s = PDFAnnotation(bounds: r.insetBy(dx: -lineWidth, dy: -lineWidth), forType: tool == .rect ? .square : .circle, withProperties: nil)
            s.color = color
            s.border = border()
            a = s
        case .arrow:
            let r = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
                .insetBy(dx: -8, dy: -8)
            let l = PDFAnnotation(bounds: r, forType: .line, withProperties: nil)
            l.startPoint = CGPoint(x: start.x - r.minX, y: start.y - r.minY)
            l.endPoint = CGPoint(x: p.x - r.minX, y: p.y - r.minY)
            l.endLineStyle = .openArrow
            l.color = color
            l.border = border()
            a = l
        default: a = nil
        }
        if let a { page.addAnnotation(a); preview = a }
    }

    override func mouseUp(with event: NSEvent) {
        if tool.isMarkup {
            super.mouseUp(with: event)
            if currentSelection?.string?.isEmpty == false { onMarkup?() }
            return
        }
        guard drawingTool, let page = drawPage else { return super.mouseUp(with: event) }
        defer { startPoint = nil; drawPage = nil; preview = nil; inkPoints = [] }
        guard let a = preview else { return }
        // 너무 작으면(그냥 클릭) 버림
        if a.bounds.width < 4 && a.bounds.height < 4 { page.removeAnnotation(a); return }
        onAdd?(a, page)
    }

    private func border() -> PDFBorder {
        let b = PDFBorder()
        b.lineWidth = lineWidth
        return b
    }

    private func add(_ a: PDFAnnotation, _ page: PDFPage) {
        page.addAnnotation(a)
        onAdd?(a, page)
    }

    /// 쪽 좌표의 선들로 잉크(손글씨) 주석을 만든다
    private func ink(_ strokes: [[CGPoint]], color c: NSColor? = nil) -> PDFAnnotation? {
        let all = strokes.flatMap { $0 }
        guard let minX = all.map(\.x).min(), let maxX = all.map(\.x).max(),
              let minY = all.map(\.y).min(), let maxY = all.map(\.y).max() else { return nil }
        let r = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).insetBy(dx: -lineWidth * 2, dy: -lineWidth * 2)
        let a = PDFAnnotation(bounds: r, forType: .ink, withProperties: nil)
        for s in strokes where !s.isEmpty {
            let path = NSBezierPath()
            path.move(to: CGPoint(x: s[0].x - r.minX, y: s[0].y - r.minY))
            for q in s.dropFirst() { path.line(to: CGPoint(x: q.x - r.minX, y: q.y - r.minY)) }
            if s.count == 1 { path.line(to: CGPoint(x: s[0].x - r.minX + 0.5, y: s[0].y - r.minY)) }
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            a.add(path)
        }
        a.color = c ?? color
        a.border = border()
        return a
    }

    /// 서명(0~1 좌표의 선들)을 클릭한 자리에 폭 160pt로 넣는다
    private func placeSignature(_ strokes: [[CGPoint]], at p: CGPoint, on page: PDFPage) {
        let w: CGFloat = 160
        let all = strokes.flatMap { $0 }
        let aspect = (all.map(\.y).max() ?? 1) - (all.map(\.y).min() ?? 0)
        let h = w * max(0.15, aspect)
        let scaled = strokes.map { $0.map { CGPoint(x: p.x - w / 2 + $0.x * w, y: p.y - h / 2 + $0.y * w) } }
        let old = lineWidth
        lineWidth = 1.6
        defer { lineWidth = old }
        if let a = ink(scaled, color: NSColor(calibratedRed: 0.05, green: 0.1, blue: 0.35, alpha: 1)) { add(a, page) }
    }
}

// MARK: - 모델: 주석 추가·삭제와 되돌리기

extension ViewerModel {
    func setupAnnotationHandlers() {
        pdfView.onAdd = { [weak self] a, page in self?.annotationAdded(a, page) }
        pdfView.onRemove = { [weak self] a, page in self?.annotationRemoved(a, page) }
        pdfView.onMarkup = { [weak self] in self?.applyMarkup() }
        pdfView.askText = { title, message in Self.askText(title: title, message: message) }
        pdfView.signature = { [weak self] in
            if let s = SignatureStore.load() { return s }
            self?.showSignaturePad = true
            return nil
        }
    }

    private func annotationAdded(_ a: PDFAnnotation, _ page: PDFPage) {
        isDirty = true
        annotUndo?.registerUndo(withTarget: self) { m in
            page.removeAnnotation(a)
            m.annotationRemoved(a, page)
        }
        if annotUndo?.isUndoing == false && annotUndo?.isRedoing == false { annotUndo?.setActionName("주석 추가") }
    }

    private func annotationRemoved(_ a: PDFAnnotation, _ page: PDFPage) {
        isDirty = true
        annotUndo?.registerUndo(withTarget: self) { m in
            page.addAnnotation(a)
            m.annotationAdded(a, page)
        }
        if annotUndo?.isUndoing == false && annotUndo?.isRedoing == false { annotUndo?.setActionName("주석 삭제") }
    }

    private var annotUndo: UndoManager? { pdfView.window?.undoManager ?? pdfView.undoManager }

    /// 형광펜·밑줄·취소선을 선택한 글에 적용
    func applyMarkup() {
        guard let sel = pdfView.currentSelection else { return }
        let type: PDFAnnotationSubtype
        let color: NSColor
        switch annotTool {
        case .underline: type = .underline; color = pdfView.color
        case .strike: type = .strikeOut; color = pdfView.color
        default: type = .highlight; color = NSColor.systemYellow.withAlphaComponent(0.5)
        }
        annotUndo?.beginUndoGrouping()
        for line in sel.selectionsByLine() {
            for page in line.pages {
                let a = PDFAnnotation(bounds: line.bounds(for: page), forType: type, withProperties: nil)
                a.color = annotTool == .highlight
                    ? (annotColorChosen ? NSColor(annotColor) : NSColor.systemYellow).withAlphaComponent(0.45) : color
                page.addAnnotation(a)
                annotationAdded(a, page)
            }
        }
        annotUndo?.endUndoGrouping()
        annotUndo?.setActionName(annotTool.label)
        pdfView.clearSelection()
    }

    static func askText(title: String, message: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "넣기")
        alert.addButton(withTitle: "취소")
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        field.font = .systemFont(ofSize: 13)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        scroll.documentView = field
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        alert.accessoryView = scroll
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 주석 도구 막대

struct AnnotationBar: View {
    @EnvironmentObject var model: ViewerModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AnnotTool.allCases) { t in
                Button { model.annotTool = t } label: {
                    Image(systemName: t.icon).frame(width: 28, height: 24)
                }
                .buttonStyle(.plain)
                .background(RoundedRectangle(cornerRadius: 6).fill(model.annotTool == t ? Color.accentColor.opacity(0.25) : .clear))
                .help(t.help)
                if t == .select || t == .strike || t == .text || t == .arrow { Divider().frame(height: 18).padding(.horizontal, 3) }
            }
            ColorPicker("", selection: $model.annotColor, supportsOpacity: false).labelsHidden().frame(width: 36)
                .help("색")
            Picker("", selection: $model.annotLineWidth) {
                Text("가늘게").tag(1.0)
                Text("보통").tag(2.0)
                Text("굵게").tag(4.0)
            }
            .labelsHidden().frame(width: 76).help("선 굵기")
            Spacer()
            Text(model.annotTool.help).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Button("서명 만들기…") { model.showSignaturePad = true }.controlSize(.small)
            Button { model.showAnnotationBar = false; model.annotTool = .select } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).help("주석 막대 닫기")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }
}

// MARK: - 서명

enum SignatureStore {
    private static let key = "signatureStrokes"
    /// 0~1 좌표(가로 기준)의 선들
    static func load() -> [[CGPoint]]? {
        guard let arr = UserDefaults.standard.array(forKey: key) as? [[[Double]]], !arr.isEmpty else { return nil }
        return arr.map { $0.map { CGPoint(x: $0[0], y: $0[1]) } }
    }
    static func save(_ strokes: [[CGPoint]]) {
        UserDefaults.standard.set(strokes.map { $0.map { [Double($0.x), Double($0.y)] } }, forKey: key)
    }
}

/// 서명 그리기 판
struct SignaturePad: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var model: ViewerModel
    @State private var strokes: [[CGPoint]] = []
    @State private var current: [CGPoint] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("서명 만들기").font(.title3.bold())
            Text("트랙패드나 마우스로 아래 칸에 서명하세요. 저장해 두면 '서명' 도구로 클릭 한 번에 넣을 수 있습니다.")
                .font(.callout).foregroundStyle(.secondary)
            Canvas { ctx, _ in
                for s in strokes + [current] where s.count > 1 {
                    var p = Path()
                    p.addLines(s)
                    ctx.stroke(p, with: .color(Color(red: 0.05, green: 0.1, blue: 0.35)), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                }
            }
            .frame(width: 520, height: 200)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.4)))
            .overlay(alignment: .bottom) { Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 1).padding(.horizontal, 30).padding(.bottom, 50) }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { current.append($0.location) }
                .onEnded { _ in strokes.append(current); current = [] })
            HStack {
                Button("지우기") { strokes = []; current = [] }
                Spacer()
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("저장") { save() }.buttonStyle(.borderedProminent).disabled(strokes.isEmpty)
            }
        }
        .padding(22)
    }

    /// 화면 좌표(위쪽 원점) → 0~1(가로 기준, 아래쪽 원점)
    private func save() {
        let all = strokes.flatMap { $0 }
        guard let minX = all.map(\.x).min(), let maxX = all.map(\.x).max(),
              let minY = all.map(\.y).min(), let maxY = all.map(\.y).max() else { return }
        let w = max(1, maxX - minX)
        SignatureStore.save(strokes.map { $0.map { CGPoint(x: ($0.x - minX) / w, y: (maxY - $0.y) / w) } })
        _ = minY
        model.annotTool = .signature
        model.statusMessage = "서명을 저장했습니다 — 문서를 클릭하면 그 자리에 들어갑니다"
        dismiss()
    }
}

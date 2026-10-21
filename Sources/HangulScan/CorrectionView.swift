import SwiftUI
import PDFKit

/// 인식 결과 교정: 확인이 필요한 줄(주황)을 보고 고치거나 다른 후보를 눌러 바꾼다.
/// '적용'하면 쪽의 검색용 글자층이 고친 글자로 다시 만들어진다.
struct CorrectionView: View {
    @EnvironmentObject var model: ViewerModel
    @Environment(\.dismiss) private var dismiss

    @State private var pageIndex = 0
    @State private var lines: [OCRLine] = []
    @State private var edits: [Int: [OCRLine]] = [:]      // 고친 쪽들
    @State private var image: NSImage?
    @State private var selected: Int?
    @State private var onlyReview = false
    @State private var loading = false
    @State private var blocker: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                canvas.frame(minWidth: 420)
                lineList.frame(minWidth: 400)
            }
            .frame(minWidth: 980, minHeight: 600)
            Divider()
            footer
        }
        .onAppear { load(model.currentPage) }
    }

    // MARK: 머리글

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("인식 결과 교정").font(.title3.bold())
                Text("주황색 줄은 인식이 애매했던 곳입니다. 고친 내용은 검색·복사용 글자에 반영됩니다.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("확인 필요한 줄만", isOn: $onlyReview).toggleStyle(.switch)
        }
        .padding(14)
    }

    // MARK: 왼쪽: 쪽 그림 + 줄 위치

    private var canvas: some View {
        GeometryReader { geo in
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                if let image {
                    let fit = fitRect(image.size, in: geo.size)
                    Image(nsImage: image).resizable().frame(width: fit.width, height: fit.height)
                        .position(x: fit.midX, y: fit.midY)
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        let r = lineRect(line.box, fit)
                        Rectangle()
                            .fill((line.needsReview ? Color.orange : Color.blue).opacity(selected == i ? 0.3 : 0.08))
                            .overlay(Rectangle().stroke(line.needsReview ? Color.orange : Color.blue.opacity(0.5),
                                                        lineWidth: selected == i ? 2.5 : 1))
                            .frame(width: r.width, height: r.height)
                            .position(x: r.midX, y: r.midY)
                            .onTapGesture { selected = i }
                    }
                } else if loading {
                    ProgressView("이 쪽을 인식하는 중…")
                }
                if let blocker {
                    Text(blocker).foregroundStyle(.secondary).padding()
                        .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
                }
            }
        }
    }

    private func fitRect(_ img: CGSize, in box: CGSize) -> CGRect {
        let s = min((box.width - 24) / img.width, (box.height - 24) / img.height)
        let w = img.width * s, h = img.height * s
        return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
    }

    /// 쪽 기준(아래쪽 원점 0~1) 상자 → 화면 좌표
    private func lineRect(_ b: CGRect, _ fit: CGRect) -> CGRect {
        CGRect(x: fit.minX + b.minX * fit.width, y: fit.minY + (1 - b.maxY) * fit.height,
               width: b.width * fit.width, height: max(4, b.height * fit.height))
    }

    // MARK: 오른쪽: 줄 목록

    private var visible: [Int] { lines.indices.filter { !onlyReview || lines[$0].needsReview } }

    private var lineList: some View {
        ScrollViewReader { proxy in
            List(selection: $selected) {
                Section {
                    ForEach(visible, id: \.self) { i in
                        LineRow(line: safeLine(i), selected: selected == i) { markEdited() }
                            .tag(i)
                            .id(i)
                    }
                } header: {
                    let n = lines.filter(\.needsReview).count
                    Text("\(pageIndex + 1)쪽 · \(lines.count)줄" + (n > 0 ? " · 확인 필요 \(n)줄" : ""))
                }
            }
            .onChange(of: selected) { _, s in if let s { withAnimation { proxy.scrollTo(s, anchor: .center) } } }
        }
    }

    // MARK: 아래: 쪽 이동·적용

    private var footer: some View {
        HStack(spacing: 10) {
            Button { go(pageIndex - 1) } label: { Label("이전 쪽", systemImage: "chevron.left") }
                .disabled(pageIndex == 0)
            Text("\(pageIndex + 1) / \(model.pageCount)").monospacedDigit().foregroundStyle(.secondary)
            Button { go(pageIndex + 1) } label: { Label("다음 쪽", systemImage: "chevron.right") }
                .disabled(pageIndex >= model.pageCount - 1)
            Button("확인 필요한 다음 쪽") { goNextReview() }
                .disabled(nextReviewPage() == nil)
            Spacer()
            if !edits.isEmpty { Text("고친 쪽 \(edits.count)개").foregroundStyle(.secondary) }
            Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("적용") {
                saveCurrent()
                model.applyCorrections(edits)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .disabled(edits.isEmpty)
        }
        .padding(14)
    }

    /// 쪽을 넘기는 순간 목록이 바뀌어도 꺼지지 않도록 범위를 확인하는 연결
    private func safeLine(_ i: Int) -> Binding<OCRLine> {
        Binding(get: { lines.indices.contains(i) ? lines[i] : OCRLine(text: "", box: .zero, confidence: 1) },
                set: { if lines.indices.contains(i) { lines[i] = $0 } })
    }

    // MARK: 동작

    private func markEdited() { edits[pageIndex] = lines }

    private func saveCurrent() { if edits[pageIndex] != nil { edits[pageIndex] = lines } }

    private func go(_ i: Int) {
        guard i >= 0, i < model.pageCount else { return }
        saveCurrent()
        load(i)
    }

    private func load(_ i: Int) {
        pageIndex = i
        selected = nil
        lines = []
        image = nil
        blocker = model.correctionBlocker(i)
        guard blocker == nil, let page = model.document?.page(at: i) else { return }
        image = page.thumbnail(of: NSSize(width: 1400, height: 1400), for: .mediaBox)
        if let e = edits[i] { lines = e; return }
        loading = true
        model.linesForCorrection(i) { l in
            loading = false
            guard pageIndex == i else { return }
            lines = l ?? []
            if l == nil { blocker = "이 쪽을 인식하지 못했습니다." }
            selected = lines.firstIndex(where: \.needsReview)
        }
    }

    private func nextReviewPage() -> Int? {
        guard pageIndex + 1 < model.pageCount else { return nil }
        return (pageIndex + 1..<model.pageCount).first { model.pageLines[$0]?.contains(where: \.needsReview) == true }
    }

    private func goNextReview() { if let n = nextReviewPage() { go(n) } }
}

/// 줄 하나: 애매한 글자 표시 + 입력칸 + 다른 후보 단추
private struct LineRow: View {
    @Binding var line: OCRLine
    let selected: Bool
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                if line.needsReview {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                }
                Text(marked).font(.callout)
            }
            TextField("", text: Binding(get: { line.text }, set: { line.text = $0; line.uncertain = []; onEdit() }))
                .textFieldStyle(.roundedBorder)
            if !line.alternatives.isEmpty {
                HStack(spacing: 4) {
                    Text("다른 후보:").font(.caption).foregroundStyle(.secondary)
                    ForEach(line.alternatives, id: \.self) { alt in
                        Button(alt) {
                            line.text = alt
                            line.uncertain = []
                            line.confidence = 1
                            onEdit()
                        }
                        .buttonStyle(.bordered).controlSize(.small).lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// 애매한 글자를 주황 밑줄로 표시
    private var marked: AttributedString {
        var a = AttributedString()
        for (i, ch) in line.text.enumerated() {
            var piece = AttributedString(String(ch))
            if line.uncertain.contains(i) {
                piece.foregroundColor = .orange
                piece.underlineStyle = .single
                piece.font = .callout.bold()
            }
            a += piece
        }
        return a
    }
}

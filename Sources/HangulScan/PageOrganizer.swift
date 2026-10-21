import SwiftUI
import PDFKit
import UniformTypeIdentifiers

/// 페이지 정리: 전체 쪽을 격자로 보고 끌어서 순서 바꾸기, 여러 쪽 선택해 삭제·회전·추출.
/// '적용'을 누를 때 한 번에 문서에 반영되고 ⌘Z로 되돌릴 수 있다.
struct PageOrganizerView: View {
    @EnvironmentObject var model: ViewerModel
    @Environment(\.dismiss) private var dismiss

    struct Item: Identifiable, Equatable {
        let id = UUID()
        let page: PDFPage
        let original: Int          // 원래 쪽 번호(0부터)
        var rotation: Int
        static func == (a: Item, b: Item) -> Bool { a.id == b.id && a.rotation == b.rotation }
    }

    @State private var items: [Item] = []
    @State private var selection: Set<UUID> = []
    @State private var anchor: UUID?
    @State private var dragging: Item?
    @State private var thumbs: [ObjectIdentifier: NSImage] = [:]
    @State private var changed = false

    private let columns = [GridItem(.adaptive(minimum: 132, maximum: 170), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("페이지 정리").font(.title3.bold())
                    Text("끌어서 순서를 바꾸고, ⌘·⇧ 클릭으로 여러 쪽을 고르세요. '적용'을 눌러야 반영됩니다.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(items.count)쪽 · \(selection.count)쪽 선택").foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(16)
            Divider()

            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                        cell(idx, item)
                            .onDrag {
                                dragging = item
                                return NSItemProvider(object: item.id.uuidString as NSString)
                            }
                            .onDrop(of: [.text], delegate: ReorderDrop(target: item, items: $items,
                                                                       dragging: $dragging, changed: $changed))
                    }
                }
                .padding(18)
            }
            .frame(minWidth: 860, minHeight: 520)
            .background(Color(nsColor: .underPageBackgroundColor))
            .onTapGesture { selection = [] }

            Divider()
            HStack(spacing: 10) {
                Group {
                    Button { rotateSelected(-90) } label: { Label("왼쪽 회전", systemImage: "rotate.left") }
                    Button { rotateSelected(90) } label: { Label("오른쪽 회전", systemImage: "rotate.right") }
                    Button { moveSelected(toFront: true) } label: { Label("맨 앞으로", systemImage: "arrow.up.to.line") }
                    Button { moveSelected(toFront: false) } label: { Label("맨 뒤로", systemImage: "arrow.down.to.line") }
                    Button(role: .destructive) { deleteSelected() } label: { Label("삭제", systemImage: "trash") }
                        .keyboardShortcut(.delete, modifiers: [])
                    Button { extractSelected() } label: { Label("따로 저장…", systemImage: "square.and.arrow.up") }
                }
                .disabled(selection.isEmpty)
                Button("전체 선택") { selection = Set(items.map(\.id)) }
                    .keyboardShortcut("a")
                Spacer()
                Button("취소") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("적용") { apply() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!changed || items.isEmpty)
            }
            .labelStyle(.titleAndIcon)
            .padding(14)
        }
        .onAppear(perform: load)
    }

    // MARK: 칸

    private func cell(_ idx: Int, _ item: Item) -> some View {
        let selected = selection.contains(item.id)
        return VStack(spacing: 6) {
            ZStack {
                if let img = thumbs[ObjectIdentifier(item.page)] {
                    Image(nsImage: img).resizable().scaledToFit()
                        .rotationEffect(.degrees(Double(item.rotation - item.page.rotation)))
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 124, height: 160)
            .background(Color.white.opacity(0.001))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? Color.accentColor : .clear, lineWidth: 3))
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            .task { makeThumb(item.page) }
            HStack(spacing: 4) {
                Text("\(idx + 1)").font(.caption.bold())
                if idx != item.original {
                    Text("(원래 \(item.original + 1))").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.15) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { click(item) }
    }

    private func makeThumb(_ page: PDFPage) {
        let k = ObjectIdentifier(page)
        guard thumbs[k] == nil else { return }
        thumbs[k] = page.thumbnail(of: NSSize(width: 248, height: 320), for: .cropBox)
    }

    // MARK: 선택

    private func click(_ item: Item) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift), let a = anchor,
           let i = items.firstIndex(where: { $0.id == a }), let j = items.firstIndex(where: { $0.id == item.id }) {
            selection.formUnion(items[min(i, j)...max(i, j)].map(\.id))
        } else if flags.contains(.command) {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
            anchor = item.id
        } else {
            selection = [item.id]
            anchor = item.id
        }
    }

    // MARK: 편집

    private func load() {
        guard let doc = model.document else { return }
        items = (0..<doc.pageCount).compactMap { i in
            doc.page(at: i).map { Item(page: $0, original: i, rotation: $0.rotation) }
        }
        if let cur = items.indices.contains(model.currentPage) ? items[model.currentPage].id : nil { selection = [cur]; anchor = cur }
    }

    private func rotateSelected(_ deg: Int) {
        for i in items.indices where selection.contains(items[i].id) {
            items[i].rotation = (items[i].rotation + deg + 360) % 360
        }
        changed = true
    }

    private func moveSelected(toFront: Bool) {
        let picked = items.filter { selection.contains($0.id) }
        let rest = items.filter { !selection.contains($0.id) }
        withAnimation { items = toFront ? picked + rest : rest + picked }
        changed = true
    }

    private func deleteSelected() {
        guard selection.count < items.count else {
            model.errorMessage = "모든 쪽을 지울 수는 없습니다. 최소 한 쪽은 남겨 주세요."
            return
        }
        withAnimation { items.removeAll { selection.contains($0.id) } }
        selection = []
        changed = true
    }

    private func extractSelected() {
        let picked = items.filter { selection.contains($0.id) }
        model.extractPages(picked.map(\.page), rotations: picked.map(\.rotation))
    }

    private func apply() {
        let removed = (model.document?.pageCount ?? 0) - items.count
        let firstSelected = items.firstIndex { selection.contains($0.id) } ?? 0
        model.applyPages(items.map(\.page), rotations: items.map(\.rotation), actionName: "페이지 정리", goTo: firstSelected)
        model.statusMessage = removed > 0
            ? "페이지 정리를 적용했습니다 (\(removed)쪽 삭제) — ⌘Z로 되돌리기"
            : "페이지 정리를 적용했습니다 — ⌘Z로 되돌리기"
        dismiss()
    }
}

/// 끌어다 놓는 동안 실시간으로 자리를 바꿔 보여 줌
private struct ReorderDrop: DropDelegate {
    let target: PageOrganizerView.Item
    @Binding var items: [PageOrganizerView.Item]
    @Binding var dragging: PageOrganizerView.Item?
    @Binding var changed: Bool

    func dropEntered(info: DropInfo) {
        guard let d = dragging, d.id != target.id,
              let from = items.firstIndex(where: { $0.id == d.id }),
              let to = items.firstIndex(where: { $0.id == target.id }) else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            items.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
        changed = true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

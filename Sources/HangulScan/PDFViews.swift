import SwiftUI
import PDFKit

struct PDFKitView: NSViewRepresentable {
    let pdfView: PDFView
    func makeNSView(context: Context) -> PDFView { pdfView }
    func updateNSView(_ nsView: PDFView, context: Context) {}
}

struct ThumbnailsView: NSViewRepresentable {
    let pdfView: PDFView
    var pageCount: Int = 0

    final class Coordinator { var lastCount = -1 }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> PDFThumbnailView {
        let v = PDFThumbnailView()
        v.pdfView = pdfView
        v.thumbnailSize = CGSize(width: 150, height: 200)
        v.backgroundColor = .clear
        v.allowsMultipleSelection = false
        return v
    }
    func updateNSView(_ nsView: PDFThumbnailView, context: Context) {
        if nsView.pdfView !== pdfView || context.coordinator.lastCount != pageCount {
            // 페이지 삭제·합치기 뒤 목록을 새로 그리도록 연결을 다시 맺음
            nsView.pdfView = nil
            nsView.pdfView = pdfView
            context.coordinator.lastCount = pageCount
        }
    }
}

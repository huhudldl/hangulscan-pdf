import SwiftUI
import AVFoundation
import Translation
import FoundationModels
import NaturalLanguage

// MARK: - 문서 글자 꺼내기 (도우미 기능 공통)

extension ViewerModel {
    /// 쪽의 글자: 이번에 인식한 결과, 없으면 파일 안의 진짜 글자층
    func textForAssist(_ i: Int) -> String {
        if let t = pageTexts[i], !t.isEmpty { return t }
        guard let page = document?.page(at: i), PDFTextProbe.hasText(page) else { return "" }
        return page.string ?? ""
    }

    var selectedText: String? {
        let s = pdfView.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty ?? true) ? nil : s
    }

    /// OCR 줄바꿈을 정리: 문장 끝이 아닌 줄바꿈은 띄어쓰기로 이어 붙임 (읽기·번역이 자연스럽게)
    static func joinLines(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        var out = ""
        for l in lines where !l.isEmpty {
            if out.isEmpty { out = l; continue }
            let ends = out.last.map { ".!?。”\"」』:;)".contains($0) } ?? true
            out += ends ? "\n" + l : " " + l
        }
        return out
    }
}

// MARK: - ⑩ 읽어주기

final class SpeechReader: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = SpeechReader()
    @Published private(set) var isSpeaking = false
    @Published private(set) var isPaused = false
    @Published private(set) var spoken = ""          // 지금 읽는 부분
    @Published var rate: Double = UserDefaults.standard.object(forKey: "ttsRate") as? Double ?? 0.5 {
        didSet { UserDefaults.standard.set(rate, forKey: "ttsRate") }
    }
    @Published var continuous = true
    var onFinish: (() -> Void)?

    private let synth = AVSpeechSynthesizer()
    private var text = ""

    override init() {
        super.init()
        synth.delegate = self
    }

    /// 가장 품질 좋은 한국어 목소리
    private var voice: AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("ko") }
            .max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: "ko-KR")
    }

    func speak(_ t: String) {
        synth.stopSpeaking(at: .immediate)
        text = t
        let u = AVSpeechUtterance(string: t)
        u.voice = voice
        u.rate = Float(AVSpeechUtteranceMinimumSpeechRate + (AVSpeechUtteranceMaximumSpeechRate - AVSpeechUtteranceMinimumSpeechRate) * Float(rate))
        isSpeaking = true
        isPaused = false
        synth.speak(u)
    }

    func togglePause() {
        if synth.isPaused { synth.continueSpeaking(); isPaused = false }
        else if synth.isSpeaking { synth.pauseSpeaking(at: .word); isPaused = true }
    }

    func stop() {
        onFinish = nil
        synth.stopSpeaking(at: .immediate)
        isSpeaking = false
        isPaused = false
        spoken = ""
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString r: NSRange, utterance: AVSpeechUtterance) {
        let ns = text as NSString
        // 지금 읽는 문장을 보여 줌
        let sentence = ns.paragraphRange(for: r)
        DispatchQueue.main.async { self.spoken = ns.substring(with: sentence).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isSpeaking = false
            self.spoken = ""
            if self.continuous, let next = self.onFinish { next() }
        }
    }
}

extension ViewerModel {
    /// 현재 쪽(또는 선택한 글)을 소리 내어 읽기. '다음 쪽 계속'이면 끝까지 이어 읽음
    func readAloud(from page: Int? = nil) {
        let reader = SpeechReader.shared
        if page == nil, let sel = selectedText {
            reader.onFinish = nil
            reader.speak(sel)
            return
        }
        var i = page ?? currentPage
        // 글자 없는 쪽은 건너뜀
        while i < pageCount && textForAssist(i).isEmpty { i += 1 }
        guard i < pageCount else {
            statusMessage = page == nil ? "읽을 글자가 없습니다 — 스캔 문서라면 먼저 한국어 OCR을 실행하세요" : "문서 끝까지 읽었습니다"
            reader.stop()
            return
        }
        goTo(page: i)
        reader.onFinish = { [weak self] in self?.readAloud(from: i + 1) }
        reader.speak(Self.joinLines(textForAssist(i)))
    }
}

struct ReadAloudSection: View {
    @EnvironmentObject var model: ViewerModel
    @ObservedObject var reader = SpeechReader.shared

    var body: some View {
        Section {
            HStack {
                if reader.isSpeaking {
                    Button { reader.togglePause() } label: {
                        Label(reader.isPaused ? "계속" : "일시정지", systemImage: reader.isPaused ? "play.fill" : "pause.fill")
                    }
                    Button { reader.stop() } label: { Label("정지", systemImage: "stop.fill") }
                } else {
                    Button { model.readAloud() } label: {
                        Label(model.selectedText != nil ? "선택한 글 읽기" : "이 쪽부터 읽기", systemImage: "speaker.wave.2.fill")
                    }
                    .disabled(model.document == nil)
                }
            }
            HStack {
                Image(systemName: "tortoise").foregroundStyle(.secondary)
                Slider(value: $reader.rate, in: 0.2...0.8)
                Image(systemName: "hare").foregroundStyle(.secondary)
            }
            Toggle("다음 쪽 계속 읽기", isOn: $reader.continuous)
            if !reader.spoken.isEmpty {
                Text(reader.spoken).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
        } header: {
            Text("읽어주기")
        } footer: {
            Text("글을 드래그해 선택하면 그 부분만 읽습니다. 더 자연스러운 목소리는 시스템 설정 › 손쉬운 사용 › 읽기 및 말하기에서 한국어 '고품질' 목소리를 내려받으세요.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - ⑪ 번역 (macOS 내장 번역, 기기 안에서)

struct TranslateSection: View {
    @EnvironmentObject var model: ViewerModel
    @State private var target = "en"
    @State private var config: TranslationSession.Configuration?
    @State private var source = ""
    @State private var result = ""
    @State private var busy = false
    @State private var error: String?

    private let targets = [("en", "영어"), ("ko", "한국어"), ("ja", "일본어"), ("zh-Hans", "중국어(간체)")]

    var body: some View {
        Section {
            Picker("번역할 언어", selection: $target) {
                ForEach(targets, id: \.0) { Text($0.1).tag($0.0) }
            }
            HStack {
                Button(model.selectedText != nil ? "선택한 글 번역" : "이 쪽 번역") { start() }
                    .disabled(model.document == nil || busy)
                if busy { ProgressView().controlSize(.small) }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            if !result.isEmpty {
                ScrollView {
                    Text(result).font(.system(size: 12.5)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 100, maxHeight: 260)
                Button("번역문 복사") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result, forType: .string)
                }
            }
        } header: {
            Text("번역")
        } footer: {
            Text("macOS 내장 번역을 씁니다. 처음 쓰는 언어는 언어 파일 내려받기를 묻습니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .translationTask(config) { session in
            await translate(with: session)
        }
    }

    private func start() {
        let text = model.selectedText ?? ViewerModel.joinLines(model.textForAssist(model.currentPage))
        guard !text.isEmpty else {
            error = "번역할 글자가 없습니다 — 스캔 문서라면 먼저 한국어 OCR을 실행하세요."
            return
        }
        error = nil
        result = ""
        source = text
        // 글 전체의 주 언어를 한 번만 판별 (줄마다 판별하면 영어 줄 하나 때문에 실패함)
        let r = NLLanguageRecognizer()
        r.processString(text)
        let lang = r.dominantLanguage?.rawValue ?? "ko"
        let targetBase = target.split(separator: "-").first.map(String.init) ?? target
        if lang.hasPrefix(targetBase) {
            error = "이미 \(targets.first { $0.0 == target }?.1 ?? target)로 된 글입니다. 다른 언어를 고르세요."
            return
        }
        busy = true
        // 같은 언어로 다시 눌러도 새로 번역하도록 설정을 새로 만듦
        config = TranslationSession.Configuration(source: Locale.Language(identifier: lang), target: Locale.Language(identifier: target))
    }

    private func translate(with session: TranslationSession) async {
        defer { busy = false }
        do {
            try await session.prepareTranslation()
            // 문단 단위로 나눠 번역 (긴 쪽도 끊기지 않게)
            var out: [String] = []
            for para in source.components(separatedBy: "\n") where !para.trimmingCharacters(in: .whitespaces).isEmpty {
                // 한 문단이 실패해도(예: 이미 영어인 줄) 원문을 두고 계속
                let translated = (try? await session.translate(para))?.targetText ?? para
                out.append(translated)
                result = out.joined(separator: "\n")
            }
        } catch {
            self.error = "번역하지 못했습니다: \(error.localizedDescription)"
        }
    }
}

// MARK: - ⑫ 요약·질문 (Apple Intelligence, 기기 안에서)

@MainActor
final class DocumentAssistant: ObservableObject {
    @Published var output = ""
    @Published var busy = false
    @Published var status = ""
    private var task: Task<Void, Never>?

    /// 한 번에 넘길 글자 수 (기기 안 모델의 처리 분량 4096토큰에 맞춤)
    private let chunkChars = 1200
    private let instructions = "당신은 한국어 문서 도우미입니다. 항상 한국어로, 문서에 있는 내용만 근거로 간결하게 답하세요."

    var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible): return "이 Mac은 Apple Intelligence를 지원하지 않습니다."
        case .unavailable(.appleIntelligenceNotEnabled): return "시스템 설정 › Apple Intelligence 및 Siri에서 Apple Intelligence를 켜 주세요."
        case .unavailable(.modelNotReady): return "AI 모델을 준비하는 중입니다. 잠시 후 다시 시도하세요."
        case .unavailable: return "지금은 기기 안 AI를 쓸 수 없습니다."
        }
    }

    func cancel() { task?.cancel(); busy = false; status = "취소했습니다" }

    /// 쪽 글자들을 처리 분량에 맞는 덩어리로 (쪽 번호 표시 유지)
    private func chunks(_ pages: [(Int, String)]) -> [String] {
        var out: [String] = [], cur = ""
        for (i, t) in pages {
            var rest = ViewerModel.joinLines(t)
            while !rest.isEmpty {
                let room = max(200, chunkChars - cur.count)
                let piece = String(rest.prefix(room))
                rest = String(rest.dropFirst(piece.count))
                cur += "[\(i + 1)쪽] " + piece + "\n"
                if cur.count >= chunkChars { out.append(cur); cur = "" }
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    func summarize(_ pages: [(Int, String)]) {
        run { [self] in
            var parts = chunks(pages)
            guard !parts.isEmpty else { output = "요약할 글자가 없습니다 — 스캔 문서라면 먼저 한국어 OCR을 실행하세요."; return }
            // 길면: 부분 요약 → 종합 (필요하면 여러 번)
            var round = 1
            while parts.count > 1 {
                var partials: [String] = []
                for (k, p) in parts.enumerated() {
                    try Task.checkCancellation()
                    status = "부분 요약 \(k + 1)/\(parts.count)" + (round > 1 ? " (\(round)단계)" : "")
                    let s = LanguageModelSession(instructions: instructions)
                    let r = try await s.respond(to: "다음 문서 일부의 핵심을 2~3문장으로 요약하세요. 쪽 번호 표시는 유지하세요.\n\n\(p)")
                    partials.append(r.content)
                }
                parts = chunks(partials.enumerated().map { ($0.offset, $0.element) }).map { $0.replacingOccurrences(of: #"\[\d+쪽\] "#, with: "", options: .regularExpression) }
                if parts.count > 1 { round += 1 } else { parts = [partials.joined(separator: "\n")] }
            }
            status = "요약 정리 중…"
            let s = LanguageModelSession(instructions: instructions)
            let stream = s.streamResponse(to: "다음 내용을 바탕으로 문서 전체를 글머리표 5개 이내로 요약하세요. 같은 내용은 한 번만 쓰세요.\n\n\(parts[0])")
            for try await snap in stream { output = snap.content }
        }
    }

    func ask(_ question: String, pages: [(Int, String)]) {
        run { [self] in
            // 질문과 겹치는 글자(두 글자 묶음)가 많은 쪽을 근거로 고름
            let q = question.replacingOccurrences(of: " ", with: "")
            let grams = Set(zip(q, q.dropFirst()).map { String([$0, $1]) })
            let scored = pages.map { (i, t) -> (Int, String, Int) in
                let flat = t.replacingOccurrences(of: " ", with: "")
                return (i, t, grams.reduce(0) { $0 + (flat.contains($1) ? 1 : 0) })
            }.filter { $0.2 > 0 }.sorted { $0.2 > $1.2 }
            guard !scored.isEmpty else { output = "문서에서 관련 내용을 찾지 못했습니다."; return }
            var context = ""
            var used: [Int] = []
            var seenTexts = Set<String>()
            for (i, t, _) in scored where context.count < 1800 && used.count < 4 {
                let joined = ViewerModel.joinLines(t)
                guard seenTexts.insert(joined).inserted else { continue }   // 같은 내용의 쪽은 한 번만
                context += "[\(i + 1)쪽] " + String(joined.prefix(1800 - context.count)) + "\n"
                used.append(i + 1)
            }
            status = "답을 만드는 중…"
            let s = LanguageModelSession(instructions: instructions)
            let prompt = """
            [문서 발췌]의 내용만으로 질문에 한두 문장으로 답하세요.
            발췌에 답이 전혀 없을 때만 "문서에서 찾을 수 없습니다"라고만 답하세요.

            [문서 발췌]
            \(context)
            [질문] \(question)
            """
            for try await snap in s.streamResponse(to: prompt) { output = snap.content }
            if ProcessInfo.processInfo.environment["HS_DEBUG"] != nil { print("[발췌]\n\(context)\n[원래 답]\n\(output)") }
            // 답이 있는데 덧붙은 '찾을 수 없습니다' 줄은 지우고, 근거 쪽은 직접 붙임
            let notFound = "문서에서 찾을 수 없습니다"
            let lines = output.components(separatedBy: "\n")
            let kept = lines.filter { !$0.contains(notFound) && !$0.trimmingCharacters(in: CharacterSet(charactersIn: "*-• ")).isEmpty }
            if kept.isEmpty {
                output = notFound + "."
            } else {
                output = kept.joined(separator: "\n") + "\n\n근거: " + used.prefix(2).map { "\($0)쪽" }.joined(separator: ", ")
            }
        }
    }

    private func run(_ body: @escaping () async throws -> Void) {
        task?.cancel()
        output = ""
        busy = true
        status = ""
        task = Task {
            do { try await body(); status = "" }
            catch is CancellationError { status = "취소했습니다" }
            catch let e as LanguageModelSession.GenerationError {
                switch e {
                case .exceededContextWindowSize: output = "글이 너무 길어 처리하지 못했습니다. 범위를 '현재 쪽'으로 줄여 보세요."
                case .guardrailViolation: output = "안전 기준 때문에 이 내용은 처리할 수 없습니다."
                case .unsupportedLanguageOrLocale: output = "이 언어는 지원하지 않습니다."
                default: output = "AI 처리 중 오류: \(e.localizedDescription)"
                }
            }
            catch { output = "AI 처리 중 오류: \(error.localizedDescription)" }
            busy = false
        }
    }
}

struct AISection: View {
    @EnvironmentObject var model: ViewerModel
    @StateObject private var ai = DocumentAssistant()
    @State private var scope = 0          // 0 현재 쪽, 1 전체 문서
    @State private var question = ""

    private var pages: [(Int, String)] {
        let range = scope == 0 ? model.currentPage..<min(model.currentPage + 1, model.pageCount) : 0..<model.pageCount
        return range.map { ($0, model.textForAssist($0)) }.filter { !$0.1.isEmpty }
    }

    var body: some View {
        Section {
            if let reason = ai.unavailableReason {
                Text(reason).font(.callout).foregroundStyle(.orange)
            } else {
                Picker("범위", selection: $scope) {
                    Text("현재 쪽").tag(0)
                    Text("전체 문서").tag(1)
                }
                .pickerStyle(.segmented)
                HStack {
                    Button { ai.summarize(pages) } label: { Label("요약하기", systemImage: "text.badge.star") }
                        .disabled(model.document == nil || ai.busy)
                    if ai.busy {
                        ProgressView().controlSize(.small)
                        Button("취소") { ai.cancel() }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("문서에 대해 물어보기").font(.callout)
                    HStack {
                        TextField("", text: $question, prompt: Text("예: 행사 장소가 어디야?"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(ask)
                        Button("질문", action: ask).disabled(question.isEmpty || ai.busy || model.document == nil)
                    }
                }
                if !ai.status.isEmpty { Text(ai.status).font(.caption).foregroundStyle(.secondary) }
                if !ai.output.isEmpty {
                    ScrollView {
                        Text(Self.tidy(ai.output)).font(.system(size: 12.5)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 100, maxHeight: 300)
                    Button("결과 복사") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ai.output, forType: .string)
                    }
                }
            }
        } header: {
            Text("요약 · 질문 (Apple Intelligence)")
        } footer: {
            Text("인터넷 없이 Mac 안에서 처리합니다. 질문에는 관련 있는 쪽만 골라 근거로 답하며, AI 답이 틀릴 수 있으니 근거 쪽을 확인하세요.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// AI 답의 마크다운 기호를 읽기 좋게 (글머리표 *, - → •, 굵게 ** 제거)
    static func tidy(_ s: String) -> String {
        s.components(separatedBy: "\n").map { line -> String in
            var l = line.replacingOccurrences(of: "**", with: "")
            if let r = l.range(of: #"^\s*[\*\-]\s+"#, options: .regularExpression) { l.replaceSubrange(r, with: "• ") }
            return l
        }.joined(separator: "\n")
    }

    private func ask() {
        guard !question.isEmpty else { return }
        // 질문은 범위와 상관없이 문서 전체에서 근거를 찾음
        let all = (0..<model.pageCount).map { ($0, model.textForAssist($0)) }.filter { !$0.1.isEmpty }
        ai.ask(question, pages: all)
    }
}

/// 도우미 탭
struct AssistantPanel: View {
    var body: some View {
        Form {
            ReadAloudSection()
            TranslateSection()
            AISection()
        }
        .formStyle(.grouped)
    }
}

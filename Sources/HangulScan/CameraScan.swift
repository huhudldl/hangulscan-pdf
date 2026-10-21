import SwiftUI
import AVFoundation
import Vision
import CoreImage

/// 카메라 실시간 스캔: 문서 테두리 감지 + 수평계 + 수평이 맞고 흔들림이 없으면 자동 촬영
final class CameraController: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var devices: [AVCaptureDevice] = []
    @Published var selectedID = ""
    @Published var quad: Quad?
    @Published var tilt: Double?
    @Published var frameSize = CGSize(width: 1920, height: 1080)
    @Published var stability = 0.0
    @Published var autoCapture = true { didSet { let v = autoCapture; queue.async { self.autoFlag = v } } }
    @Published var status = "카메라 준비 중…"
    @Published var permissionDenied = false
    @Published var flash = false

    let session = AVCaptureSession()
    var onCapture: ((CIImage) -> Void)?

    static let levelTolerance = 2.0   // 이 각도 이내면 '수평'
    private let queue = DispatchQueue(label: "camera.video")
    private let output = AVCaptureVideoDataOutput()
    private var lastAnalysis = Date.distantPast
    private var lastQuad: Quad?
    private var capturedQuad: Quad?
    private var stableCount = 0
    private var needsMovement = false
    private var captureRequested = false
    private var autoFlag = true
    private var cooldownUntil = Date.distantPast
    private let requiredStable = 5

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async { ok ? self.configure() : (self.permissionDenied = true) }
            }
        default: permissionDenied = true
        }
    }

    func stop() { queue.async { if self.session.isRunning { self.session.stopRunning() } } }

    private func configure() {
        let found = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.continuityCamera, .builtInWideAngleCamera, .external],
            mediaType: .video, position: .unspecified).devices
        devices = found
        // 문서 촬영엔 iPhone(연속성 카메라)이 훨씬 좋으므로 우선 선택
        guard let d = found.first(where: { $0.deviceType == .continuityCamera }) ?? found.first else {
            status = "사용 가능한 카메라가 없습니다"
            return
        }
        select(d.uniqueID)
    }

    func select(_ id: String) {
        guard let d = devices.first(where: { $0.uniqueID == id }) else { return }
        selectedID = id
        status = "\(d.localizedName) 연결 중…"
        queue.async { self.setup(device: d) }
    }

    private func setup(device: AVCaptureDevice) {
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) { session.addInput(input) }
        } catch {
            session.commitConfiguration()
            DispatchQueue.main.async { self.status = "카메라를 열 수 없습니다: \(error.localizedDescription)" }
            return
        }
        if session.outputs.isEmpty {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) { session.addOutput(output) }
        }
        session.commitConfiguration()
        if !session.isRunning { session.startRunning() }
        DispatchQueue.main.async { self.status = "문서를 화면 안에 놓아 주세요" }
    }

    func capture() { queue.async { self.captureRequested = true } }

    // MARK: 프레임 분석

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if captureRequested {
            captureRequested = false
            grab(pb, quad: lastQuad)
            return
        }
        let now = Date()
        guard now.timeIntervalSince(lastAnalysis) > 0.12 else { return }
        lastAnalysis = now

        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let req = VNDetectDocumentSegmentationRequest()
        try? VNImageRequestHandler(cvPixelBuffer: pb, options: [:]).perform([req])
        var q: Quad?
        if let o = req.results?.first, o.confidence > 0.5 {
            let cand = Quad(o)
            if cand.area > 0.08 { q = cand }
        }
        let tilt = q.map { $0.tiltDegrees(width: w, height: h) }

        if let q, let last = lastQuad, q.maxDistance(to: last) < 0.012 { stableCount += 1 } else { stableCount = 0 }
        if needsMovement {
            if q == nil || (capturedQuad.map { q!.maxDistance(to: $0) > 0.08 } ?? true) { needsMovement = false }
        }
        lastQuad = q

        let level = tilt.map { abs($0) < Self.levelTolerance } ?? false
        let ready = q != nil && level && !needsMovement && now > cooldownUntil
        let progress = ready ? min(1, Double(stableCount) / Double(requiredStable)) : 0
        let fire = autoFlag && ready && stableCount >= requiredStable

        let statusText: String
        if q == nil { statusText = needsMovement ? "다음 페이지로 넘겨 주세요" : "문서를 찾는 중…" }
        else if needsMovement { statusText = "촬영 완료 — 다음 페이지로 넘겨 주세요" }
        else if !level { statusText = "수평을 맞춰 주세요" }
        else { statusText = autoFlag ? "수평 OK — 움직이지 마세요" : "수평 OK — 촬영하세요" }

        DispatchQueue.main.async {
            self.quad = q
            self.tilt = tilt
            self.frameSize = CGSize(width: w, height: h)
            self.stability = progress
            self.status = statusText
        }
        if fire {
            grab(pb, quad: q)
            needsMovement = true
            capturedQuad = q
            stableCount = 0
            cooldownUntil = now.addingTimeInterval(1.0)
        }
    }

    private func grab(_ pb: CVPixelBuffer, quad: Quad?) {
        let ci = CIImage(cvPixelBuffer: pb)
        guard let cg = ImageProcessor.context.createCGImage(ci, from: ci.extent) else { return }
        let image = CIImage(cgImage: cg)
        DispatchQueue.main.async {
            self.flash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.flash = false }
            NSSound(named: "Tink")?.play()
            self.onCapture?(image)
        }
    }
}

// MARK: - 미리보기 (문서 테두리 오버레이)

final class CameraPreviewNSView: NSView {
    let previewLayer: AVCaptureVideoPreviewLayer
    private let overlay = CAShapeLayer()
    private let guide = CAShapeLayer()

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        previewLayer.videoGravity = .resizeAspect
        layer?.addSublayer(previewLayer)
        guide.strokeColor = NSColor.white.withAlphaComponent(0.35).cgColor
        guide.lineWidth = 1
        guide.lineDashPattern = [6, 6]
        guide.fillColor = nil
        layer?.addSublayer(guide)
        overlay.lineWidth = 3
        overlay.lineJoin = .round
        layer?.addSublayer(overlay)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        overlay.frame = bounds
        guide.frame = bounds
        // 수평 기준선 (가로 3등분)
        let p = CGMutablePath()
        for i in 1...2 {
            let y = bounds.height * CGFloat(i) / 3
            p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: bounds.width, y: y))
        }
        guide.path = p
        CATransaction.commit()
        if let c = previewLayer.connection {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = false   // 글자가 거꾸로 보이지 않도록
        }
    }

    func update(quad: Quad?, frameSize: CGSize, level: Bool) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let q = quad, frameSize.width > 0 else { overlay.path = nil; return }
        // resizeAspect로 표시된 영상 영역 계산 (레이어 좌표는 왼쪽 아래 원점 = Vision과 동일)
        let s = min(bounds.width / frameSize.width, bounds.height / frameSize.height)
        let vw = frameSize.width * s, vh = frameSize.height * s
        let ox = (bounds.width - vw) / 2, oy = (bounds.height - vh) / 2
        let pts = q.points.map { CGPoint(x: ox + $0.x * vw, y: oy + $0.y * vh) }
        let path = CGMutablePath()
        path.addLines(between: pts)
        path.closeSubpath()
        overlay.path = path
        let color = level ? NSColor.systemGreen : NSColor.systemOrange
        overlay.strokeColor = color.cgColor
        overlay.fillColor = color.withAlphaComponent(0.15).cgColor
    }
}

struct CameraPreview: NSViewRepresentable {
    @ObservedObject var camera: CameraController
    func makeNSView(context: Context) -> CameraPreviewNSView { CameraPreviewNSView(session: camera.session) }
    func updateNSView(_ v: CameraPreviewNSView, context: Context) {
        v.update(quad: camera.quad, frameSize: camera.frameSize,
                 level: camera.tilt.map { abs($0) < CameraController.levelTolerance } ?? false)
    }
}

// MARK: - 수평계

struct LevelIndicator: View {
    let tilt: Double?
    let progress: Double

    var body: some View {
        let t = tilt ?? 0
        let ok = tilt.map { abs($0) < CameraController.levelTolerance } ?? false
        let color: Color = tilt == nil ? .gray : (ok ? .green : (abs(t) < 6 ? .orange : .red))
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(.black.opacity(0.55))
                Circle().stroke(.white.opacity(0.25), lineWidth: 1)
                // 고정된 수평 기준
                Rectangle().fill(.white.opacity(0.5)).frame(width: 96, height: 1.5)
                // 문서의 현재 기울기
                Capsule().fill(color).frame(width: 84, height: 5)
                    .rotationEffect(.degrees(-t))
                    .animation(.easeOut(duration: 0.15), value: t)
                Circle().trim(from: 0, to: progress)
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(3)
            }
            .frame(width: 112, height: 112)

            Group {
                if let tilt {
                    if ok {
                        Text(String(format: "수평 %.1f°", abs(tilt)))
                    } else {
                        Text(String(format: "%@으로 %.1f° 돌리세요", tilt > 0 ? "시계방향" : "반시계방향", abs(tilt)))
                    }
                } else {
                    Text("문서 감지 대기")
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.85)))
        }
    }
}

// MARK: - 카메라 스캔 화면

struct CameraScanView: View {
    @EnvironmentObject var model: ViewerModel
    @StateObject private var camera = CameraController()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text("카메라 스캔").font(.title3.bold())
                Spacer()
                if camera.devices.count > 1 {
                    Picker("카메라", selection: Binding(get: { camera.selectedID }, set: { camera.select($0) })) {
                        ForEach(camera.devices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                    }
                    .frame(width: 260)
                }
                Toggle("책 모드", isOn: $model.settings.bookMode)
                    .help("펼친 책을 찍으면 양쪽을 두 쪽으로 나누고 휜 줄을 폅니다")
                Toggle("수평 맞으면 자동 촬영", isOn: $camera.autoCapture)
            }
            .padding(12)

            ZStack {
                if camera.permissionDenied {
                    VStack(spacing: 10) {
                        Image(systemName: "video.slash").font(.largeTitle)
                        Text("카메라 접근 권한이 없습니다")
                        Text("시스템 설정 › 개인정보 보호 및 보안 › 카메라에서 '한글스캔 PDF'를 허용해 주세요.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    CameraPreview(camera: camera)
                    VStack {
                        HStack {
                            Text(camera.status)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Capsule().fill(.black.opacity(0.6)))
                            Spacer()
                            LevelIndicator(tilt: camera.tilt, progress: camera.stability)
                        }
                        Spacer()
                    }
                    .padding(14)
                    if camera.flash { Color.white.opacity(0.7).allowsHitTesting(false) }
                }
            }
            .frame(minWidth: 860, minHeight: 540)
            .background(.black)

            HStack(spacing: 10) {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(model.scannedPages.suffix(12)) { p in
                            Image(nsImage: NSImage(cgImage: p.thumbnail, size: .zero))
                                .resizable().scaledToFit().frame(height: 54)
                                .border(Color.secondary.opacity(0.3))
                        }
                        if model.pendingScanCount > 0 { ProgressView().controlSize(.small) }
                    }
                }
                .frame(height: 60)
                Text("\(model.scannedPages.count + model.pendingScanCount)쪽")
                    .foregroundStyle(.secondary).monospacedDigit()
                Button {
                    camera.capture()
                } label: {
                    Label("촬영", systemImage: "camera.circle.fill").frame(minWidth: 80)
                }
                .keyboardShortcut(.space, modifiers: [])
                .controlSize(.large)
                Button("완료") { model.finishCamera() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .onAppear {
            camera.onCapture = { [weak model] img in model?.importScans([.image(img)]) }
            camera.start()
        }
        .onDisappear { camera.stop() }
    }
}

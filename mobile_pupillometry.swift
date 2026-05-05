import SwiftUI
import UIKit
import AVFoundation
import Photos
import Combine

// MARK: - Force landscape-only

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        [.landscapeLeft, .landscapeRight]
    }
}

@main
struct PupilCameraApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene { WindowGroup { ContentView() } }
}

// MARK: - UI enums

enum PreviewMode: String, CaseIterable, Identifiable {
    case fit  = "Fit (see all)"
    case fill = "Fill (crop)"
    var id: String { rawValue }
}

enum RotationChoice: String, CaseIterable, Identifiable {
    case deg0   = "0°"
    case deg90  = "90°"
    case deg180 = "180°"
    case deg270 = "270°"

    var id: String { rawValue }

    var angle: CGFloat {
        switch self {
        case .deg0:   return 0
        case .deg90:  return 90
        case .deg180: return 180
        case .deg270: return 270
        }
    }
}

// MARK: - Zoom level

enum ZoomLevel: String, CaseIterable, Identifiable {
    case x1 = "1x (Wide)"
    case x2 = "2x (Tele)"
    var id: String { rawValue }
}

// MARK: - HID Keyboard Trigger

final class HIDKeyboardTriggerController: UIViewController {

    var onTrigger: (() -> Void)?

    override var canBecomeFirstResponder: Bool { true }
    override var canResignFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override var keyCommands: [UIKeyCommand] {
        [
            UIKeyCommand(input: "a", modifierFlags: [],      action: #selector(hidKeyReceived)),
            UIKeyCommand(input: "a", modifierFlags: .shift,  action: #selector(hidKeyReceived)),
        ]
    }

    @objc private func hidKeyReceived() {
        onTrigger?()
    }
}

// MARK: - SwiftUI wrapper that hosts HIDKeyboardTriggerController

struct HIDKeyboardTriggerView: UIViewControllerRepresentable {
    let controller: HIDKeyboardTriggerController

    func makeUIViewController(context: Context) -> HIDKeyboardTriggerController { controller }
    func updateUIViewController(_ uiViewController: HIDKeyboardTriggerController, context: Context) {}
}

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var camera = CameraController()

    @State private var hidController = HIDKeyboardTriggerController()

    @FocusState private var durationFocused: Bool

    // Drawer
    @State private var drawerOpen: Bool = true
    @State private var drawerDragX: CGFloat = 0

    // Preview options
    @State private var previewMode: PreviewMode = .fit
    @State private var rotationChoice: RotationChoice = .deg90

    // Zoom
    @State private var zoomLevel: ZoomLevel = .x1

    // Macro
    @State private var macroMode: Bool = false

    // Auto-stop
    @State private var useAutoStop = true
    @State private var durationText: String = "10"

    // Exposure
    @State private var manualExposure = true
    @State private var isoValue: Float = 200
    @State private var shutterMs: Double = 8.3  // 1/120s — safe default well within 24fps
    @State private var whiteBalanceK: Float = 4500  // Kelvin, 2000=warm 8000=cool

    // Focus
    @State private var manualFocus = true
    @State private var focusValue: Float = 0.5

    // Advanced settings (collapsed by default)
    @State private var advancedExpanded: Bool = false
    @State private var videoStabilization: Bool = false
    @State private var geometricDistortionCorrection: Bool = false
    @State private var wideColor: Bool = false
    @State private var exposureBias: Float = 0.0  // set to max on first applySettings

    var body: some View {
        GeometryReader { geo in
            let drawerWidth  = max(340, geo.size.width * 0.36)
            let handleWidth: CGFloat = 34
            let closedOffset = drawerWidth - handleWidth

            ZStack(alignment: .trailing) {

                // CAMERA full screen
                ZStack(alignment: .topLeading) {
                    Color.black.ignoresSafeArea()

                    CameraPreviewView(
                        session: camera.session,
                        previewMode: previewMode,
                        rotationAngle: rotationChoice.angle,
                        camera: camera
                    )
                    .ignoresSafeArea()

                    // Status overlay
                    HStack(spacing: 10) {
                        Circle().frame(width: 10, height: 10)
                            .foregroundStyle(camera.isRecording ? .red : .green)

                        Text(camera.isRecording ? "REC" : "READY")
                            .font(.system(size: 14, weight: .bold))

                        Text(camera.elapsedString)
                            .font(.system(size: 14))
                            .monospacedDigit()

                        // Zoom badge
                        Text(zoomLevel == .x2 ? "2×" : "1×")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.yellow)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .padding(12)
                }

                // SLIDING DRAWER
                drawerView()
                    .frame(width: drawerWidth, height: geo.size.height)
                    .offset(x: (drawerOpen ? 0 : closedOffset) + drawerDragX)
                    .gesture(
                        DragGesture()
                            .onChanged { g in drawerDragX = g.translation.width }
                            .onEnded { g in
                                let predicted = g.predictedEndTranslation.width
                                let threshold: CGFloat = 60
                                if drawerOpen {
                                    if predicted > threshold  { drawerOpen = false }
                                } else {
                                    if predicted < -threshold { drawerOpen = true  }
                                }
                                drawerDragX = 0
                            }
                    )
                    .animation(.spring(response: 0.25, dampingFraction: 0.9), value: drawerOpen)
            }
            .onAppear {
                camera.start(useZoom2x: false)

                hidController.onTrigger = {
                    camera.logEvent("HID_KEY_RECEIVED")
                    if !camera.isRecording { toggleRecording(source: "HID_REMOTE") }
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    applySettings()
                    camera.setRecordingRotation(angle: rotationChoice.angle)
                }
            }
            .onChange(of: rotationChoice) { _, _ in
                camera.setRecordingRotation(angle: rotationChoice.angle)
            }
            .onChange(of: zoomLevel) { _, newValue in
                // Do not switch cameras mid-recording
                guard !camera.isRecording else {
                    camera.logEvent("ZOOM_CHANGE_BLOCKED_RECORDING")
                    return
                }
                camera.reconfigureSession(useZoom2x: newValue == .x2)
                camera.logEvent("ZOOM_CHANGED_\(newValue.rawValue)")
            }
        }
        .onTapGesture {
            durationFocused = false
            UIApplication.shared.endEditing()
        }
        .onChange(of: durationFocused) { _, focused in
            if !focused {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    hidController.becomeFirstResponder()
                }
            }
        }
        .overlay(
            HIDKeyboardTriggerView(controller: hidController)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
        )
    }

    // MARK: - Drawer UI

    private func drawerView() -> some View {
        HStack(spacing: 0) {

            // Handle tab
            VStack {
                Spacer()
                Button { drawerOpen.toggle() } label: {
                    VStack(spacing: 8) {
                        Image(systemName: drawerOpen ? "chevron.right" : "chevron.left")
                            .font(.system(size: 16, weight: .bold))
                        RoundedRectangle(cornerRadius: 3)
                            .frame(width: 6, height: 40)
                            .opacity(0.6)
                    }
                    .frame(width: 34, height: 120)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.leading, 8)
                }
                Spacer()
            }
            .frame(width: 50)

            // Panel
            ScrollView {
                VStack(spacing: 14) {
                    Text("Pupil Camera Controls")
                        .font(.system(size: 18, weight: .bold))
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // Preview settings
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Preview", selection: $previewMode) {
                            ForEach(PreviewMode.allCases) { m in Text(m.rawValue).tag(m) }
                        }
                        .pickerStyle(.segmented)

                        Picker("Rotation", selection: $rotationChoice) {
                            ForEach(RotationChoice.allCases) { r in Text(r.rawValue).tag(r) }
                        }
                        .pickerStyle(.segmented)

                        Text("If the preview is sideways: use 90° or 270°. Upside-down: 180°.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    // ── Zoom ──────────────────────────────────────────────
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Zoom (optical)")
                            .font(.system(size: 14, weight: .semibold))

                        Picker("Zoom", selection: $zoomLevel) {
                            ForEach(ZoomLevel.allCases) { z in Text(z.rawValue).tag(z) }
                        }
                        .pickerStyle(.segmented)

                        if camera.isRecording {
                            Text("⚠️ Stop recording before changing zoom.")
                                .font(.system(size: 12))
                                .foregroundStyle(.orange)
                        } else {
                            Text("2x uses the telephoto lens (true optical, no crop).")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    // ─────────────────────────────────────────────────────

                    // ── Macro ─────────────────────────────────────────────
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Macro Mode", isOn: Binding(
                            get: { macroMode },
                            set: { enabled in
                                macroMode = enabled
                                if enabled {
                                    // Switch to ultrawide (0.5x) for close focus
                                    zoomLevel  = .x1
                                    focusValue = 0.0
                                    if !camera.isRecording {
                                        camera.reconfigureSessionMacro(
                                            ultraWide: true,
                                            manualExposure: manualExposure, iso: isoValue, shutterMs: shutterMs,
                                            whiteBalanceK: whiteBalanceK,
                                            manualFocus: manualFocus, lensPosition: 0.0
                                        )
                                    }
                                    camera.logEvent("MACRO_ON_ULTRAWIDE")
                                } else {
                                    // Return to wide camera
                                    if !camera.isRecording {
                                        camera.reconfigureSession(useZoom2x: zoomLevel == .x2)
                                    }
                                    applySettings()
                                    camera.logEvent("MACRO_OFF")
                                }
                            }
                        ))

                        Text(macroMode
                             ? "Ultrawide lens · use focus slider to fine-tune close distance."
                             : "Switches to ultrawide lens for close-up subjects (a few cm).")
                            .font(.system(size: 12))
                            .foregroundStyle(macroMode ? .orange : .secondary)
                    }
                    .padding(12)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    // ─────────────────────────────────────────────────────

                    // Auto-stop
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Auto-stop after duration", isOn: $useAutoStop)

                        HStack {
                            Text("Seconds").frame(width: 70, alignment: .leading)

                            TextField("10", text: $durationText)
                                .keyboardType(.numberPad)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 110)
                                .focused($durationFocused)

                            Text("10 / 15 / 120")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") {
                                durationFocused = false
                                UIApplication.shared.endEditing()
                            }
                        }
                    }
                    .padding(12)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    // Record button
                    Button { toggleRecording(source: "UI") } label: {
                        Text(camera.isRecording ? "STOP (SAVE)" : "START (AUTO-SAVE)")
                            .font(.system(size: 16, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(camera.isRecording ? Color.red.opacity(0.9) : Color.green.opacity(0.9))
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    // Exposure
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Manual Exposure", isOn: Binding(
                            get: { manualExposure },
                            set: { manualExposure = $0; applySettings() }
                        ))

                        if manualExposure {
                            // ISO — range pulled live from the active device
                            HStack {
                                Text("ISO").frame(width: 70, alignment: .leading)
                                Slider(value: Binding(
                                    get: { Double(isoValue) },
                                    set: { isoValue = Float($0); applySettings() }
                                ), in: camera.minISO...camera.maxISO, step: 1)
                                Text("\(Int(isoValue))")
                                    .frame(width: 55, alignment: .trailing)
                                    .monospacedDigit()
                            }

                            // Shutter — range pulled live from active device
                            HStack {
                                Text("Shutter").frame(width: 70, alignment: .leading)
                                Slider(value: Binding(
                                    get: { shutterMs },
                                    set: { shutterMs = $0; applySettings() }
                                ), in: camera.minShutterMs...camera.maxShutterMs, step: 0.1)
                                Text(String(format: "%.1fms", shutterMs))
                                    .frame(width: 70, alignment: .trailing)
                                    .monospacedDigit()
                            }

                            // White balance
                            HStack {
                                Text("W.Balance").frame(width: 70, alignment: .leading)
                                Slider(value: Binding(
                                    get: { Double(whiteBalanceK) },
                                    set: { whiteBalanceK = Float($0); applySettings() }
                                ), in: 2000...8000, step: 50)
                                Text("\(Int(whiteBalanceK))K")
                                    .frame(width: 70, alignment: .trailing)
                                    .monospacedDigit()
                            }
                        } else {
                            Text("Auto exposure active — may drift with IR light.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    // Focus — disabled in macro mode (macro uses its own focus on switch)
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Manual Focus", isOn: Binding(
                            get: { manualFocus },
                            set: { manualFocus = $0; applySettings() }
                        ))
                        .disabled(macroMode)

                        if macroMode {
                            Text("Focus slider active in macro mode — use below.")
                                .font(.system(size: 12))
                                .foregroundStyle(.orange)

                            HStack {
                                Text("Focus").frame(width: 70, alignment: .leading)
                                Slider(value: Binding(
                                    get: { Double(focusValue) },
                                    set: {
                                        focusValue = Float($0)
                                        camera.setFocus(manual: true, lensPosition: focusValue)
                                    }
                                ), in: 0.0...1.0, step: 0.01)
                                Text(String(format: "%.2f", focusValue))
                                    .frame(width: 70, alignment: .trailing)
                                    .monospacedDigit()
                            }
                        } else if manualFocus {
                            HStack {
                                Text("Focus").frame(width: 70, alignment: .leading)
                                Slider(value: Binding(
                                    get: { Double(focusValue) },
                                    set: { focusValue = Float($0); applySettings() }
                                ), in: 0.0...1.0, step: 0.01)
                                Text(String(format: "%.2f", focusValue))
                                    .frame(width: 70, alignment: .trailing)
                                    .monospacedDigit()
                            }
                        } else {
                            Text("Auto focus active.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    // ── Advanced Settings (collapsed by default) ──────────
                    VStack(alignment: .leading, spacing: 10) {

                        // Header / toggle
                        Button {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                                advancedExpanded.toggle()
                            }
                        } label: {
                            HStack {
                                Text("Advanced Settings")
                                    .font(.system(size: 14, weight: .semibold))
                                Spacer()
                                Image(systemName: advancedExpanded ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 12, weight: .bold))
                            }
                            .foregroundStyle(.primary)
                        }

                        if advancedExpanded {

                            // Video Stabilization
                            Toggle(isOn: Binding(
                                get: { videoStabilization },
                                set: { videoStabilization = $0; applySettings() }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Video Stabilization")
                                        .font(.system(size: 13, weight: .medium))
                                    Text("OFF = no frame crop, recommended for IR")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Divider()

                            // Geometric Distortion Correction
                            Toggle(isOn: Binding(
                                get: { geometricDistortionCorrection },
                                set: { geometricDistortionCorrection = $0; applySettings() }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Lens Distortion Correction")
                                        .font(.system(size: 13, weight: .medium))
                                    Text("OFF = raw lens output, no warping")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Divider()

                            // Wide Color P3
                            Toggle(isOn: Binding(
                                get: { wideColor },
                                set: { wideColor = $0; applySettings() }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Wide Color (P3)")
                                        .font(.system(size: 13, weight: .medium))
                                    Text("OFF = no extra color processing, best for IR")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Divider()

                            // Exposure Target Bias (EV)
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("EV Bias").font(.system(size: 13, weight: .medium))
                                    Spacer()
                                    Text(String(format: "%+.1f EV", exposureBias))
                                        .font(.system(size: 12))
                                        .monospacedDigit()
                                        .foregroundStyle(exposureBias > 0 ? .orange : .secondary)
                                }
                                Slider(value: Binding(
                                    get: { Double(exposureBias) },
                                    set: { exposureBias = Float($0); applySettings() }
                                ), in: Double(camera.minEVBias)...Double(camera.maxEVBias), step: 0.1)
                                Text("Pushes overall brightness up/down on top of ISO+shutter. Max = brightest.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(12)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    // ─────────────────────────────────────────────────────

                    Button {
                        applySettings()
                        camera.logEvent("UI_APPLY_SETTINGS")
                    } label: {
                        Text("Apply Settings")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.blue.opacity(0.85))
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    Spacer(minLength: 20)
                }
                .padding(14)
            }
            .background(.ultraThinMaterial)
        }
    }

    // MARK: - Actions

    private func toggleRecording(source: String) {
        if camera.isRecording {
            camera.stopRecording(event: "\(source)_STOP")
            return
        }

        camera.setRecordingRotation(angle: rotationChoice.angle)

        let secs     = Double(durationText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let duration = useAutoStop ? max(0, secs) : 0

        camera.startRecording(event: "\(source)_START", autoStopAfterSeconds: duration)
    }

    private func applySettings() {
        // On very first call, set EV bias to max if still at default 0.0
        if exposureBias == 0.0 {
            exposureBias = camera.maxEVBias
        }
        camera.setExposure(manual: manualExposure, iso: isoValue, shutterMs: shutterMs)
        camera.setFocus(manual: manualFocus, lensPosition: focusValue)
        camera.setWhiteBalance(temperatureK: whiteBalanceK)
        camera.setAdvancedSettings(
            stabilization: videoStabilization,
            geometricCorrection: geometricDistortionCorrection,
            wideColor: wideColor,
            evBias: exposureBias
        )
    }
}

// MARK: - Preview

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    let previewMode: PreviewMode
    let rotationAngle: CGFloat
    let camera: CameraController

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.videoPreviewLayer.session = session
        apply(to: v.videoPreviewLayer)
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        apply(to: uiView.videoPreviewLayer)
    }

    private func apply(to layer: AVCaptureVideoPreviewLayer) {
        layer.videoGravity = (previewMode == .fit) ? .resizeAspect : .resizeAspectFill
        if let conn = layer.connection, conn.isVideoRotationAngleSupported(rotationAngle) {
            conn.videoRotationAngle = rotationAngle
        }
        camera.setRecordingRotation(angle: rotationAngle)
    }
}

// MARK: - Camera Controller

final class CameraController: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()
    private let q = DispatchQueue(label: "pupil.camera.session.queue")

    private let movieOutput = AVCaptureMovieFileOutput()
    private var videoDevice: AVCaptureDevice?

    @Published var isRecording  = false
    @Published var elapsedString = "00:00.0"

    // Live device capability limits — sliders read these
    @Published var minISO: Double = 50
    @Published var maxISO: Double = 800
    @Published var minShutterMs: Double = 0.5
    @Published var maxShutterMs: Double = 250.0
    @Published var minEVBias: Float = -8.0
    @Published var maxEVBias: Float = 8.0

    private var recStart: Date?
    private var timer: Timer?
    private var autoStopWorkItem: DispatchWorkItem?

    // KVO observer — watches exposureMode and snaps it back if iOS tries to change it
    private var exposureObserver: NSKeyValueObservation?
    private var wbObserver: NSKeyValueObservation?

    // Last known manual values so the KVO callback can restore them
    private var lockedISO: Float = 200
    private var lockedShutterMs: Double = 8.3
    private var lockedWBK: Float = 4500

    private lazy var logURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("camera_events.csv")
    }()

    // MARK: - Session start (initial)

    func start(useZoom2x: Bool) {
        ensureLogHeader()
        AVCaptureDevice.requestAccess(for: .video) { videoOK in
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                if !videoOK {
                    self.logEvent("PERMISSION_DENIED_CAMERA")
                    return
                }
                self.configureSession(useZoom2x: useZoom2x)
            }
        }
    }

    // MARK: - Live reconfiguration (zoom change while session is running)

    func reconfigureSession(useZoom2x: Bool) {
        q.async {
            self.session.beginConfiguration()

            // Remove existing video inputs only
            for input in self.session.inputs {
                if let deviceInput = input as? AVCaptureDeviceInput,
                   deviceInput.device.hasMediaType(.video) {
                    self.session.removeInput(deviceInput)
                }
            }

            // Pick camera
            let deviceType: AVCaptureDevice.DeviceType = useZoom2x
                ? .builtInTelephotoCamera
                : .builtInWideAngleCamera

            guard let cam = AVCaptureDevice.default(deviceType, for: .video, position: .back) else {
                // Telephoto not available — fall back to wide with digital zoom
                self.logEvent("TELEPHOTO_UNAVAILABLE_FALLBACK")
                if let fallback = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                   let fallbackInput = try? AVCaptureDeviceInput(device: fallback),
                   self.session.canAddInput(fallbackInput) {
                    self.session.addInput(fallbackInput)
                    self.videoDevice = fallback
                    // Apply 2× digital zoom as best-effort
                    if useZoom2x {
                        try? fallback.lockForConfiguration()
                        fallback.videoZoomFactor = 2.0
                        fallback.unlockForConfiguration()
                    }
                }
                self.session.commitConfiguration()
                return
            }

            do {
                let newInput = try AVCaptureDeviceInput(device: cam)
                guard self.session.canAddInput(newInput) else {
                    self.logEvent("CANNOT_ADD_VIDEO_INPUT_ZOOM")
                    self.session.commitConfiguration()
                    return
                }
                self.session.addInput(newInput)
                self.videoDevice = cam
                self.updateDeviceLimits(cam)
                self.attachLockObservers(to: cam)
                self.logEvent("ZOOM_DEVICE_SWITCHED:\(useZoom2x ? "TELE" : "WIDE")")
            } catch {
                self.logEvent("ZOOM_INPUT_ERROR:\(error.localizedDescription)")
            }

            self.session.commitConfiguration()
        }
    }

    // Switches to ultrawide for macro, or falls back to wide if ultrawide unavailable
    func reconfigureSessionMacro(ultraWide: Bool,
                                  manualExposure: Bool, iso: Float, shutterMs: Double,
                                  whiteBalanceK: Float,
                                  manualFocus: Bool, lensPosition: Float) {
        q.async {
            self.session.beginConfiguration()

            // Remove existing video inputs only
            for input in self.session.inputs {
                if let deviceInput = input as? AVCaptureDeviceInput,
                   deviceInput.device.hasMediaType(.video) {
                    self.session.removeInput(deviceInput)
                }
            }

            let targetType: AVCaptureDevice.DeviceType = ultraWide
                ? .builtInUltraWideCamera
                : .builtInWideAngleCamera

            // Try ultrawide first, fall back to wide if not found
            let cam = AVCaptureDevice.default(targetType, for: .video, position: .back)
                   ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)

            guard let cam else {
                self.logEvent("MACRO_NO_CAMERA")
                self.session.commitConfiguration()
                return
            }

            do {
                let newInput = try AVCaptureDeviceInput(device: cam)
                guard self.session.canAddInput(newInput) else {
                    self.logEvent("MACRO_CANNOT_ADD_INPUT")
                    self.session.commitConfiguration()
                    return
                }
                self.session.addInput(newInput)
                self.videoDevice = cam
                self.updateDeviceLimits(cam)
                self.attachLockObservers(to: cam)
                self.logEvent("MACRO_DEVICE:\(cam.deviceType == .builtInUltraWideCamera ? "ULTRAWIDE" : "WIDE_FALLBACK")")
            } catch {
                self.logEvent("MACRO_INPUT_ERROR:\(error.localizedDescription)")
            }

            self.session.commitConfiguration()

            // Re-apply all manual settings to the new device immediately
            self.setExposure(manual: manualExposure, iso: iso, shutterMs: shutterMs)
            self.setWhiteBalance(temperatureK: whiteBalanceK)
            self.setFocus(manual: manualFocus, lensPosition: lensPosition)
        }
    }

    private func configureSession(useZoom2x: Bool) {
        q.async {
            self.session.beginConfiguration()
            self.session.sessionPreset = .hd4K3840x2160

            for i in self.session.inputs  { self.session.removeInput(i)  }
            for o in self.session.outputs { self.session.removeOutput(o) }

            let deviceType: AVCaptureDevice.DeviceType = useZoom2x
                ? .builtInTelephotoCamera
                : .builtInWideAngleCamera

            guard let cam = AVCaptureDevice.default(deviceType, for: .video, position: .back) else {
                self.logEvent("NO_CAMERA_FOR_ZOOM:\(useZoom2x)")
                self.session.commitConfiguration()
                return
            }

            do {
                let videoInput = try AVCaptureDeviceInput(device: cam)
                guard self.session.canAddInput(videoInput) else {
                    self.logEvent("CANNOT_ADD_VIDEO_INPUT")
                    self.session.commitConfiguration()
                    return
                }
                self.session.addInput(videoInput)
                self.videoDevice = cam
                self.updateDeviceLimits(cam)
                self.attachLockObservers(to: cam)
            } catch {
                self.logEvent("VIDEO_INPUT_ERROR")
                self.session.commitConfiguration()
                return
            }

            if let mic = AVCaptureDevice.default(for: .audio),
               let micInput = try? AVCaptureDeviceInput(device: mic),
               self.session.canAddInput(micInput) {
                self.session.addInput(micInput)
            }

            if self.session.canAddOutput(self.movieOutput) {
                self.session.addOutput(self.movieOutput)
                // Use HEVC (H.265) for highest quality at 4K
                if self.movieOutput.availableVideoCodecTypes.contains(.hevc) {
                    self.movieOutput.setOutputSettings(
                        [AVVideoCodecKey: AVVideoCodecType.hevc],
                        for: self.movieOutput.connection(with: .video)!
                    )
                    self.logEvent("CODEC_HEVC")
                } else {
                    self.logEvent("CODEC_HEVC_UNAVAILABLE_USING_DEFAULT")
                }
            } else {
                self.logEvent("CANNOT_ADD_MOVIE_OUTPUT")
            }

            self.session.commitConfiguration()
            self.session.startRunning()
            self.logEvent("SESSION_STARTED_ZOOM:\(useZoom2x ? "TELE" : "WIDE")")

            // Lock to 24fps
            if let device = self.videoDevice {
                do {
                    try device.lockForConfiguration()
                    let fps24 = CMTime(value: 1, timescale: 24)
                    device.activeVideoMinFrameDuration = fps24
                    device.activeVideoMaxFrameDuration = fps24
                    device.unlockForConfiguration()
                    self.logEvent("FPS_SET_24")
                } catch {
                    self.logEvent("FPS_SET_FAILED:\(error.localizedDescription)")
                }
            }
        }
    }

    // Reads live ISO and shutter limits from the active device and publishes them
    // so the UI sliders can clamp to the correct range for each camera
    private func updateDeviceLimits(_ device: AVCaptureDevice) {
        let fmt = device.activeFormat
        let minIso = Double(fmt.minISO)
        let maxIso = Double(fmt.maxISO)
        let minSec = CMTimeGetSeconds(fmt.minExposureDuration) * 1000.0
        let maxSec = min(CMTimeGetSeconds(fmt.maxExposureDuration) * 1000.0, 41.6)
        let minEV  = device.minExposureTargetBias
        let maxEV  = device.maxExposureTargetBias
        DispatchQueue.main.async {
            self.minISO       = minIso
            self.maxISO       = maxIso
            self.minShutterMs = max(0.1, minSec)
            self.maxShutterMs = maxSec
            self.minEVBias    = minEV
            self.maxEVBias    = maxEV
        }
    }

    // Attach KVO observers to the active device so if iOS ever tries to
    // re-enable auto exposure or auto white balance we immediately snap it back
    private func attachLockObservers(to device: AVCaptureDevice) {
        exposureObserver?.invalidate()
        wbObserver?.invalidate()

        exposureObserver = device.observe(\.exposureMode, options: [.new]) { [weak self] dev, _ in
            guard let self else { return }
            // If iOS changed exposure away from custom, restore it immediately
            if dev.exposureMode != .custom {
                self.logEvent("KVO_EXPOSURE_DRIFT_DETECTED_RESTORING")
                self.setExposure(manual: true, iso: self.lockedISO, shutterMs: self.lockedShutterMs)
            }
        }

        wbObserver = device.observe(\.whiteBalanceMode, options: [.new]) { [weak self] dev, _ in
            guard let self else { return }
            if dev.whiteBalanceMode != .locked {
                self.logEvent("KVO_WB_DRIFT_DETECTED_RESTORING")
                self.setWhiteBalance(temperatureK: self.lockedWBK)
            }
        }

        self.logEvent("KVO_OBSERVERS_ATTACHED")
    }

    private func detachLockObservers() {
        exposureObserver?.invalidate()
        exposureObserver = nil
        wbObserver?.invalidate()
        wbObserver = nil
    }

    func setRecordingRotation(angle: CGFloat) {
        q.async {
            guard let conn = self.movieOutput.connection(with: .video) else { return }
            if conn.isVideoRotationAngleSupported(angle) {
                conn.videoRotationAngle = angle
            }
        }
    }

    func startRecording(event: String, autoStopAfterSeconds: Double = 0) {
        q.async {
            guard !self.movieOutput.isRecording else { return }

            self.autoStopWorkItem?.cancel()
            self.autoStopWorkItem = nil

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("rec_\(Int(Date().timeIntervalSince1970)).mov")

            self.movieOutput.startRecording(to: url, recordingDelegate: self)

            DispatchQueue.main.async {
                self.isRecording = true
                self.startTimer()
                self.recStart = Date()
                self.logEvent(event)
            }

            if autoStopAfterSeconds > 0 {
                let secs = autoStopAfterSeconds
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    if self.movieOutput.isRecording {
                        self.stopRecording(event: "AUTO_STOP_\(secs)s")
                    }
                }
                self.autoStopWorkItem = work
                self.q.asyncAfter(deadline: .now() + secs, execute: work)
            }
        }
    }

    func stopRecording(event: String) {
        q.async {
            self.autoStopWorkItem?.cancel()
            self.autoStopWorkItem = nil

            guard self.movieOutput.isRecording else { return }
            self.movieOutput.stopRecording()

            DispatchQueue.main.async {
                self.isRecording = false
                self.stopTimer()
                self.logEvent(event)
            }
        }
    }

    func setExposure(manual: Bool, iso: Float, shutterMs: Double) {
        // Store for KVO restore
        if manual { lockedISO = iso; lockedShutterMs = shutterMs }
        q.async {
            guard let d = self.videoDevice else {
                self.logEvent("EXPOSURE_NO_DEVICE")
                return
            }
            do {
                try d.lockForConfiguration()
                defer { d.unlockForConfiguration() }

                // Kill every automatic brightness/sensitivity adjustment
                if d.isLowLightBoostSupported {
                    d.automaticallyEnablesLowLightBoostWhenAvailable = false
                }
                d.automaticallyAdjustsVideoHDREnabled = false
                if d.activeFormat.isVideoHDRSupported {
                    d.isVideoHDREnabled = false
                }
                if d.activeFormat.isGlobalToneMappingSupported {
                    d.isGlobalToneMappingEnabled = false
                }
                d.isSubjectAreaChangeMonitoringEnabled = false

                if manual, d.isExposureModeSupported(.custom) {
                    let isoClamped = min(max(iso, d.activeFormat.minISO), d.activeFormat.maxISO)
                    let minDur  = d.activeFormat.minExposureDuration
                    let maxDur  = d.activeFormat.maxExposureDuration
                    let seconds = max(CMTimeGetSeconds(minDur), shutterMs / 1000.0)
                    var dur     = CMTimeMakeWithSeconds(seconds, preferredTimescale: 1_000_000)
                    if dur < minDur { dur = minDur }
                    if dur > maxDur { dur = maxDur }
                    d.setExposureModeCustom(duration: dur, iso: isoClamped, completionHandler: nil)
                    self.logEvent("EXPOSURE_SET_ISO:\(Int(isoClamped))_SHUTTER:\(String(format:"%.2f",shutterMs))ms")
                } else if d.isExposureModeSupported(.continuousAutoExposure) {
                    d.exposureMode = .continuousAutoExposure
                    self.logEvent("EXPOSURE_AUTO")
                }
            } catch {
                self.logEvent("EXPOSURE_ERROR:\(error.localizedDescription)")
            }
        }
    }

    func setFocus(manual: Bool, lensPosition: Float) {
        q.async {
            guard let d = self.videoDevice else {
                self.logEvent("FOCUS_NO_DEVICE")
                return
            }
            do {
                try d.lockForConfiguration()
                defer { d.unlockForConfiguration() }

                if manual,
                   d.isFocusModeSupported(.locked),
                   d.isLockingFocusWithCustomLensPositionSupported {
                    d.setFocusModeLocked(lensPosition: min(max(lensPosition, 0), 1), completionHandler: nil)
                    self.logEvent("FOCUS_SET:\(String(format:"%.2f",lensPosition))")
                } else if d.isFocusModeSupported(.continuousAutoFocus) {
                    d.focusMode = .continuousAutoFocus
                    self.logEvent("FOCUS_AUTO")
                }
            } catch {
                self.logEvent("FOCUS_ERROR:\(error.localizedDescription)")
            }
        }
    }

    func setWhiteBalance(temperatureK: Float) {
        lockedWBK = temperatureK  // store for KVO restore
        q.async {
            guard let d = self.videoDevice else {
                self.logEvent("WB_NO_DEVICE")
                return
            }
            guard d.isWhiteBalanceModeSupported(.locked) else {
                self.logEvent("WB_LOCKED_NOT_SUPPORTED")
                return
            }
            do {
                try d.lockForConfiguration()
                defer { d.unlockForConfiguration() }

                let tempAndTint = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                    temperature: temperatureK,
                    tint: 0.0
                )
                var gains = d.deviceWhiteBalanceGains(for: tempAndTint)

                let maxGain = d.maxWhiteBalanceGain
                gains.redGain   = min(max(gains.redGain,   1.0), maxGain)
                gains.greenGain = min(max(gains.greenGain, 1.0), maxGain)
                gains.blueGain  = min(max(gains.blueGain,  1.0), maxGain)

                // setWhiteBalanceModeLocked sets AND locks in one call —
                // do NOT also set whiteBalanceMode = .locked, that throws
                d.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
                self.logEvent("WB_SET:\(Int(temperatureK))K")
            } catch {
                self.logEvent("WB_ERROR:\(error.localizedDescription)")
            }
        }
    }

    func setAdvancedSettings(stabilization: Bool,
                              geometricCorrection: Bool,
                              wideColor: Bool,
                              evBias: Float) {
        q.async {
            guard let d = self.videoDevice else {
                self.logEvent("ADVANCED_NO_DEVICE")
                return
            }

            // ── Video Stabilization ───────────────────────────────────────
            if let conn = self.movieOutput.connection(with: .video) {
                conn.preferredVideoStabilizationMode = stabilization ? .auto : .off
                self.logEvent("STABILIZATION:\(stabilization ? "ON" : "OFF")")
            }

            do {
                try d.lockForConfiguration()
                defer { d.unlockForConfiguration() }

                // Geometric distortion correction (property is on device, not format)
                if d.isGeometricDistortionCorrectionSupported {
                    d.isGeometricDistortionCorrectionEnabled = geometricCorrection
                    self.logEvent("GDC:\(geometricCorrection ? "ON" : "OFF")")
                }

                // Wide color (P3) — this is a session-level property
                self.session.automaticallyConfiguresCaptureDeviceForWideColor = wideColor
                self.logEvent("WIDE_COLOR:\(wideColor ? "ON" : "OFF")")

                // EV Bias — clamp to device limits
                let clampedEV = min(max(evBias, d.minExposureTargetBias), d.maxExposureTargetBias)
                d.setExposureTargetBias(clampedEV, completionHandler: nil)
                self.logEvent("EV_BIAS:\(String(format:"%+.1f", clampedEV))")

            } catch {
                self.logEvent("ADVANCED_ERROR:\(error.localizedDescription)")
            }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {

        if let error = error {
            let nsError = error as NSError
            let finished = nsError.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false
            if !finished {
                logEvent("RECORDING_FAILED:\(error.localizedDescription)")
                try? FileManager.default.removeItem(at: outputFileURL)
                return
            }
            logEvent("RECORDING_FINISHED_WITH_WARNING:\(error.localizedDescription)")
        }

        logEvent("RECORDED_TEMP:\(outputFileURL.lastPathComponent)")

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                self.logEvent("PHOTOS_PERMISSION_DENIED:\(status.rawValue)")
                return
            }

            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: outputFileURL)
            }) { success, err in
                if success {
                    self.logEvent("SAVED_TO_PHOTOS:\(outputFileURL.lastPathComponent)")
                } else {
                    self.logEvent("SAVE_FAILED:\(String(describing: err))")
                }
                try? FileManager.default.removeItem(at: outputFileURL)
            }
        }
    }

    // MARK: - Timer helpers

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            guard let s = self.recStart else { return }
            let dt = Date().timeIntervalSince(s)
            self.elapsedString = Self.format(dt)
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer      = nil
        recStart   = nil
        elapsedString = "00:00.0"
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = seconds.truncatingRemainder(dividingBy: 60)
        return String(format: "%02d:%04.1f", m, s)
    }

    // MARK: - Logging

    private func ensureLogHeader() {
        if !FileManager.default.fileExists(atPath: logURL.path) {
            let header = "iso8601,epoch_seconds,event\n"
            try? header.data(using: .utf8)?.write(to: logURL)
        }
    }

    func logEvent(_ event: String) {
        let iso   = ISO8601DateFormatter().string(from: Date())
        let epoch = String(format: "%.6f", Date().timeIntervalSince1970)
        let line  = "\(iso),\(epoch),\(event)\n"
        guard let data = line.data(using: .utf8) else { return }

        q.async {
            if let handle = try? FileHandle(forWritingTo: self.logURL) {
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: self.logURL)
            }
        }
    }
}

// MARK: - UIApplication endEditing helper

extension UIApplication {
    func endEditing() {
        sendAction(#selector(UIResponder.resignFirstResponder),
                   to: nil, from: nil, for: nil)
    }
}


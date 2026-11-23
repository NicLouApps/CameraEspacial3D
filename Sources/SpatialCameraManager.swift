import AVFoundation
import CoreVideo
import UIKit

final class SpatialCameraManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum CameraStatus: Equatable {
        case starting
        case running
        case denied
        case unsupported(String)
        case error(String)
    }

    @Published var status: CameraStatus = .starting
    // 0 = 0°, 1 = 90°, 2 = 180°, 3 = 270° (correcao manual opcional caso o bloqueio de rotacao do iOS esteja ativo)
    @Published var extraQuarterTurns: Int = 0 {
        didSet {
            reapplyRotation()
        }
    }

    private let session = AVCaptureMultiCamSession()
    private let sessionQueue = DispatchQueue(label: "com.lenticular.camera.session")
    private let videoQueue = DispatchQueue(label: "com.lenticular.camera.video", qos: .userInteractive)
    private let bufferLock = NSLock()

    private let wideOutput = AVCaptureVideoDataOutput()
    private let ultraOutput = AVCaptureVideoDataOutput()
    private var wideConnection: AVCaptureConnection?
    private var ultraConnection: AVCaptureConnection?

    private var latestWideBuffer: CVPixelBuffer?
    private var latestUltraBuffer: CVPixelBuffer?
    private var isConfigured = false

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(orientationDidChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    // Mapeia a orientacao real da janela do app (LandscapeLeft / LandscapeRight / Portrait)
    private static func currentInterfaceOrientationOnMain() -> UIInterfaceOrientation {
        for scene in UIApplication.shared.connectedScenes {
            if let windowScene = scene as? UIWindowScene {
                let ori = windowScene.effectiveGeometry.interfaceOrientation
                if ori != .unknown {
                    return ori
                }
            }
        }
        switch UIDevice.current.orientation {
        case .landscapeLeft:
            return .landscapeRight
        case .landscapeRight:
            return .landscapeLeft
        case .portraitUpsideDown:
            return .portraitUpsideDown
        case .portrait:
            return .portrait
        default:
            return .landscapeRight
        }
    }

    private static func targetAngleAndOrientation(
        interfaceOri: UIInterfaceOrientation,
        extraQuarterTurns: Int
    ) -> (angle: CGFloat, videoOri: AVCaptureVideoOrientation) {
        let baseAngle: Int
        switch interfaceOri {
        case .landscapeRight:
            // Dynamic Island na esquerda (home bar na direita): sensor traseiro ja esta alinhado a 0 graus
            baseAngle = 0
        case .landscapeLeft:
            // Dynamic Island na direita: sensor traseiro a 180 graus
            baseAngle = 180
        case .portraitUpsideDown:
            baseAngle = 270
        case .portrait:
            baseAngle = 90
        default:
            baseAngle = 0
        }

        let finalAngle = (baseAngle + (extraQuarterTurns * 90)) % 360
        let videoOri: AVCaptureVideoOrientation
        switch finalAngle {
        case 0:
            videoOri = .landscapeRight
        case 180:
            videoOri = .landscapeLeft
        case 270:
            videoOri = .portraitUpsideDown
        default:
            videoOri = .portrait
        }
        return (CGFloat(finalAngle), videoOri)
    }

    func rotate90Clockwise() {
        extraQuarterTurns = (extraQuarterTurns + 1) % 4
    }

    func start() {
        let ifaceOri = Self.currentInterfaceOrientationOnMain()
        let turns = self.extraQuarterTurns
        let auth = AVCaptureDevice.authorizationStatus(for: .video)
        switch auth {
        case .authorized:
            configureAndRun(interfaceOri: ifaceOri, extraTurns: turns)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    self?.configureAndRun(interfaceOri: ifaceOri, extraTurns: turns)
                } else {
                    DispatchQueue.main.async {
                        self?.status = .denied
                    }
                }
            }
        default:
            DispatchQueue.main.async {
                self.status = .denied
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    func currentBuffers() -> (wide: CVPixelBuffer?, ultra: CVPixelBuffer?) {
        bufferLock.lock()
        let w = latestWideBuffer
        let u = latestUltraBuffer
        bufferLock.unlock()
        return (w, u)
    }

    private func configureAndRun(interfaceOri: UIInterfaceOrientation, extraTurns: Int) {
        let target = Self.targetAngleAndOrientation(interfaceOri: interfaceOri, extraQuarterTurns: extraTurns)

        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if self.isConfigured {
                self.applyConnectionRotationOnSessionQueue(angle: target.angle, videoOri: target.videoOri)
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                DispatchQueue.main.async {
                    self.status = .running
                }
                return
            }

            guard AVCaptureMultiCamSession.isMultiCamSupported else {
                DispatchQueue.main.async {
                    self.status = .unsupported("Este dispositivo não suporta captura simultânea MultiCam.")
                }
                return
            }

            guard let wideDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let ultraDevice = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) else {
                DispatchQueue.main.async {
                    self.status = .unsupported("Câmeras Principal e Ultra-Angular traseiras não encontradas.")
                }
                return
            }

            self.session.beginConfiguration()
            var configOk = true

            do {
                let wideInput = try AVCaptureDeviceInput(device: wideDevice)
                let ultraInput = try AVCaptureDeviceInput(device: ultraDevice)

                if self.session.canAddInput(wideInput) {
                    self.session.addInputWithNoConnections(wideInput)
                } else {
                    configOk = false
                }

                if self.session.canAddInput(ultraInput) {
                    self.session.addInputWithNoConnections(ultraInput)
                } else {
                    configOk = false
                }

                self.selectMultiCamFormat(for: wideDevice)
                self.selectMultiCamFormat(for: ultraDevice)

                let bgraSettings: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
                ]
                self.wideOutput.videoSettings = bgraSettings
                self.wideOutput.alwaysDiscardsLateVideoFrames = true
                self.wideOutput.setSampleBufferDelegate(self, queue: self.videoQueue)

                self.ultraOutput.videoSettings = bgraSettings
                self.ultraOutput.alwaysDiscardsLateVideoFrames = true
                self.ultraOutput.setSampleBufferDelegate(self, queue: self.videoQueue)

                if self.session.canAddOutput(self.wideOutput) {
                    self.session.addOutputWithNoConnections(self.wideOutput)
                } else {
                    configOk = false
                }

                if self.session.canAddOutput(self.ultraOutput) {
                    self.session.addOutputWithNoConnections(self.ultraOutput)
                } else {
                    configOk = false
                }

                if let widePort = wideInput.ports(
                    for: .video,
                    sourceDeviceType: wideDevice.deviceType,
                    sourceDevicePosition: wideDevice.position
                ).first {
                    let conn = AVCaptureConnection(inputPorts: [widePort], output: self.wideOutput)
                    if self.session.canAddConnection(conn) {
                        self.session.addConnection(conn)
                        self.wideConnection = conn
                    } else {
                        configOk = false
                    }
                } else {
                    configOk = false
                }

                if let ultraPort = ultraInput.ports(
                    for: .video,
                    sourceDeviceType: ultraDevice.deviceType,
                    sourceDevicePosition: ultraDevice.position
                ).first {
                    let conn = AVCaptureConnection(inputPorts: [ultraPort], output: self.ultraOutput)
                    if self.session.canAddConnection(conn) {
                        self.session.addConnection(conn)
                        self.ultraConnection = conn
                    } else {
                        configOk = false
                    }
                } else {
                    configOk = false
                }

                // Aplica a MESMA rotacao para a camera Principal e para a Ultra-Wide dentro de beginConfiguration
                self.applyConnectionRotationOnSessionQueue(angle: target.angle, videoOri: target.videoOri)
            } catch {
                configOk = false
                self.session.commitConfiguration()
                DispatchQueue.main.async {
                    self.status = .error("Falha ao inicializar câmeras: \(error.localizedDescription)")
                }
                return
            }

            self.session.commitConfiguration()

            guard configOk else {
                DispatchQueue.main.async {
                    self.status = .error("Não foi possível conectar as duas lentes no AVCaptureMultiCamSession.")
                }
                return
            }

            self.isConfigured = true
            self.session.startRunning()
            self.applyConnectionRotationOnSessionQueue(angle: target.angle, videoOri: target.videoOri)
            DispatchQueue.main.async {
                self.status = .running
            }
        }
    }

    private func selectMultiCamFormat(for device: AVCaptureDevice) {
        let candidates = device.formats.filter { fmt in
            guard fmt.isMultiCamSupported else { return false }
            let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
            let mediaSubType = CMFormatDescriptionGetMediaSubType(fmt.formatDescription)
            let is420 = mediaSubType == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                     || mediaSubType == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            return is420 && dims.width <= 1920 && dims.height <= 1080
        }

        // Prefere formatos 4:3 (ou se todos forem 16:9, escolhe o maior formato de mesma proporcao para ambas as lentes)
        let fourByThree = candidates.filter { fmt in
            let d = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
            let ratio = Double(d.width) / Double(max(1, d.height))
            return abs(ratio - (4.0 / 3.0)) < 0.08
        }
        let pool = fourByThree.isEmpty ? candidates : fourByThree

        let best = pool.max { a, b in
            let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
            let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            return (da.width * da.height) < (db.width * db.height)
        }

        guard let format = best else { return }
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            let targetFps = CMTime(value: 1, timescale: 30)
            if format.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= 30.0 && $0.minFrameRate <= 30.0 }) {
                device.activeVideoMinFrameDuration = targetFps
                device.activeVideoMaxFrameDuration = targetFps
            }
            device.unlockForConfiguration()
        } catch {}
    }

    @objc private func orientationDidChange() {
        reapplyRotation()
    }

    func reapplyRotation() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let ifaceOri = Self.currentInterfaceOrientationOnMain()
            let turns = self.extraQuarterTurns
            let target = Self.targetAngleAndOrientation(interfaceOri: ifaceOri, extraQuarterTurns: turns)
            self.sessionQueue.async {
                self.applyConnectionRotationOnSessionQueue(angle: target.angle, videoOri: target.videoOri)
            }
        }
    }

    private func applyConnectionRotationOnSessionQueue(angle: CGFloat, videoOri: AVCaptureVideoOrientation) {
        for conn in [wideConnection, ultraConnection].compactMap({ $0 }) {
            if conn.isVideoRotationAngleSupported(angle) {
                conn.videoRotationAngle = angle
            } else if conn.isVideoOrientationSupported {
                conn.videoOrientation = videoOri
            }
            if conn.isVideoMirroringSupported {
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = false
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        bufferLock.lock()
        if output === wideOutput {
            latestWideBuffer = pb
        } else if output === ultraOutput {
            latestUltraBuffer = pb
        }
        bufferLock.unlock()
    }
}

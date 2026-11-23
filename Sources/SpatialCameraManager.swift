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

    private static func currentInterfaceAngleOnMain() -> CGFloat {
        if Thread.isMainThread {
            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                switch scene.effectiveGeometry.interfaceOrientation {
                case .landscapeLeft:
                    return 180
                case .landscapeRight:
                    return 0
                case .portraitUpsideDown:
                    return 270
                default:
                    return 90
                }
            }
        }
        switch UIDevice.current.orientation {
        case .landscapeLeft:
            return 0
        case .landscapeRight:
            return 180
        case .portraitUpsideDown:
            return 270
        default:
            return 90
        }
    }

    func start() {
        let initialAngle = Self.currentInterfaceAngleOnMain()
        let auth = AVCaptureDevice.authorizationStatus(for: .video)
        switch auth {
        case .authorized:
            configureAndRun(initialAngle: initialAngle)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    self?.configureAndRun(initialAngle: initialAngle)
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

    private func configureAndRun(initialAngle: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if self.isConfigured {
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                self.applyRotationOnSessionQueue(initialAngle)
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
                        if conn.isVideoRotationAngleSupported(initialAngle) {
                            conn.videoRotationAngle = initialAngle
                        }
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
                        if conn.isVideoRotationAngleSupported(initialAngle) {
                            conn.videoRotationAngle = initialAngle
                        }
                        self.ultraConnection = conn
                    } else {
                        configOk = false
                    }
                } else {
                    configOk = false
                }
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
            self.applyRotationOnSessionQueue(initialAngle)
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

        let best = candidates.max { a, b in
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
        let angle = Self.currentInterfaceAngleOnMain()
        sessionQueue.async { [weak self] in
            self?.applyRotationOnSessionQueue(angle)
        }
    }

    private func applyRotationOnSessionQueue(_ angle: CGFloat) {
        if let wc = wideConnection, wc.isVideoRotationAngleSupported(angle) {
            wc.videoRotationAngle = angle
        }
        if let uc = ultraConnection, uc.isVideoRotationAngleSupported(angle) {
            uc.videoRotationAngle = angle
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

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

    func start() {
        let auth = AVCaptureDevice.authorizationStatus(for: .video)
        switch auth {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    self?.configureAndRun()
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

    private func configureAndRun() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if self.isConfigured {
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
            self.applyCurrentRotation()
            self.session.startRunning()
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

        // Prefere 1920x1080 ou 1280x720 com pelo menos 30 fps
        let best = candidates.max { a, b in
            let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
            let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            let pa = da.width * da.height
            let pb = db.width * db.height
            return pa < pb
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
        } catch {
            // Mantem formato padrao caso lock falhe
        }
    }

    @objc private func orientationDidChange() {
        applyCurrentRotation()
    }

    func applyCurrentRotation() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let ifaceOrientation: UIInterfaceOrientation
            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                ifaceOrientation = scene.effectiveGeometry.interfaceOrientation
            } else {
                ifaceOrientation = .portrait
            }

            let angle: CGFloat
            switch ifaceOrientation {
            case .landscapeLeft:
                angle = 180
            case .landscapeRight:
                angle = 0
            case .portraitUpsideDown:
                angle = 270
            default:
                angle = 90
            }

            self.sessionQueue.async {
                if let wc = self.wideConnection, wc.isVideoRotationAngleSupported(angle) {
                    wc.videoRotationAngle = angle
                }
                if let uc = self.ultraConnection, uc.isVideoRotationAngleSupported(angle) {
                    uc.videoRotationAngle = angle
                }
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

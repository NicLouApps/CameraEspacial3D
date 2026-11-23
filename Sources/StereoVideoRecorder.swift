import AVFoundation
import CoreVideo
import Photos
import UIKit

final class StereoVideoRecorder: ObservableObject {
    @Published var isRecording: Bool = false
    @Published var recordedSeconds: Int = 0
    @Published var toastMessage: String? = nil

    private let writerQueue = DispatchQueue(label: "com.lenticular.recorder.queue")
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var outputURL: URL?
    private var frameIndex: Int64 = 0
    private var isWritingActive = false
    private var timer: Timer?

    private(set) var activeWidth: Int = 1920
    private(set) var activeHeight: Int = 1080
    private(set) var activeAspectFit: Bool = false

    func toggleRecording(formatName: String, hasCameraSignal: Bool, useFourByThree: Bool, isSBS: Bool) {
        if isRecording {
            stopRecording(formatName: formatName)
        } else {
            guard hasCameraSignal else {
                showToast("Aguardando sinal das câmeras...")
                return
            }
            // Se o usuario escolheu 4:3 (Proporcao Original), grava o arquivo MP4 em 1440x1080 (4:3 real sem barras)
            // para Anaglifo Dubois, ou 1920x1080 para SBS 3D / 16:9 Tela Cheia
            let width = (useFourByThree && !isSBS) ? 1440 : 1920
            let height = 1080
            startRecording(width: width, height: height, aspectFit: useFourByThree)
        }
    }

    func startRecording(width: Int, height: Int, aspectFit: Bool) {
        writerQueue.async { [weak self] in
            guard let self = self, !self.isWritingActive else { return }

            self.activeWidth = width
            self.activeHeight = height
            self.activeAspectFit = aspectFit

            let fileName = "CameraEspacial3D_\(Int(Date().timeIntervalSince1970)).mp4"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: url)

            do {
                let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
                let compression: [String: Any] = [
                    AVVideoAverageBitRateKey: 14_000_000,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
                let videoSettings: [String: Any] = [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: width,
                    AVVideoHeightKey: height,
                    AVVideoCompressionPropertiesKey: compression
                ]

                let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
                input.expectsMediaDataInRealTime = true

                let sourceAttrs: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height,
                    kCVPixelBufferMetalCompatibilityKey as String: true,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:]
                ]

                let pixelAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                    assetWriterInput: input,
                    sourcePixelBufferAttributes: sourceAttrs
                )

                guard writer.canAdd(input) else {
                    self.showToast("Não foi possível configurar o gravador de vídeo.")
                    return
                }
                writer.add(input)

                guard writer.startWriting() else {
                    self.showToast("Erro ao iniciar gravação MP4.")
                    return
                }
                writer.startSession(atSourceTime: .zero)

                self.assetWriter = writer
                self.videoInput = input
                self.adaptor = pixelAdaptor
                self.outputURL = url
                self.frameIndex = 0
                self.isWritingActive = true

                DispatchQueue.main.async {
                    self.isRecording = true
                    self.recordedSeconds = 0
                    self.timer?.invalidate()
                    self.timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                        self?.recordedSeconds += 1
                    }
                }
            } catch {
                self.showToast("Falha ao criar arquivo de vídeo: \(error.localizedDescription)")
            }
        }
    }

    func allocateFrameBuffer() -> CVPixelBuffer? {
        guard isWritingActive,
              let input = videoInput,
              input.isReadyForMoreMediaData,
              let pool = adaptor?.pixelBufferPool else {
            return nil
        }
        var pb: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb)
        return (status == kCVReturnSuccess) ? pb : nil
    }

    func appendRenderedFrame(_ pixelBuffer: CVPixelBuffer) {
        writerQueue.async { [weak self] in
            guard let self = self,
                  self.isWritingActive,
                  let input = self.videoInput,
                  let adaptor = self.adaptor,
                  input.isReadyForMoreMediaData else {
                return
            }
            let pts = CMTime(value: self.frameIndex, timescale: 30)
            if adaptor.append(pixelBuffer, withPresentationTime: pts) {
                self.frameIndex += 1
            }
        }
    }

    func stopRecording(formatName: String) {
        DispatchQueue.main.async {
            self.timer?.invalidate()
            self.timer = nil
            self.isRecording = false
        }

        writerQueue.async { [weak self] in
            guard let self = self, self.isWritingActive else { return }
            self.isWritingActive = false

            guard let writer = self.assetWriter,
                  let input = self.videoInput,
                  let fileURL = self.outputURL else {
                return
            }

            let capturedFrames = self.frameIndex
            input.markAsFinished()
            writer.finishWriting { [weak self] in
                guard let self = self else { return }
                let writerStatus = writer.status
                let writerError = writer.error
                self.assetWriter = nil
                self.videoInput = nil
                self.adaptor = nil

                if capturedFrames < 2 || writerStatus != .completed {
                    try? FileManager.default.removeItem(at: fileURL)
                    let reason = writerError?.localizedDescription ?? "Grave por pelo menos 1 segundo com imagem ativa."
                    self.showToast("Gravação muito curta ou sem quadros (\(reason))")
                    return
                }

                self.saveToPhotoLibrary(url: fileURL, formatName: formatName)
            }
        }
    }

    private func saveToPhotoLibrary(url: URL, formatName: String) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard status == .authorized || status == .limited else {
                self?.showToast("Permita acesso ao Fotos em Ajustes para salvar o vídeo.")
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { success, error in
                try? FileManager.default.removeItem(at: url)
                if success {
                    self?.showToast("Vídeo \(formatName) salvo em Fotos")
                } else {
                    self?.showToast("Erro ao salvar vídeo: \(error?.localizedDescription ?? "Desconhecido")")
                }
            }
        }
    }

    private func showToast(_ msg: String) {
        DispatchQueue.main.async {
            self.toastMessage = msg
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                if self?.toastMessage == msg {
                    self?.toastMessage = nil
                }
            }
        }
    }
}

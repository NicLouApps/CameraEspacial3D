import SwiftUI
import MetalKit
import CoreVideo
import QuartzCore

struct LenticularUniforms {
    var viewportWidth: Float
    var viewportHeight: Float
    var pitch: Float
    var angleDeg: Float
    var offset: Float
    var guardPct: Float
    var swapEyes: Float
    var orientHoriz: Float
    var ultraZoom: Float
    var convergeX: Float
    var alignY: Float
    var viewMode: Float
    var wideAspect: Float
    var ultraAspect: Float
    var aspectFitMode: Float
}

struct LenticularMetalView: UIViewRepresentable {
    let cameraManager: SpatialCameraManager
    @ObservedObject var settings: CalibrationSettings
    @ObservedObject var recorder: StereoVideoRecorder

    func makeCoordinator() -> Coordinator {
        Coordinator(cameraManager: cameraManager, settings: settings, recorder: recorder)
    }

    func makeUIView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = context.coordinator.device
        mtkView.delegate = context.coordinator
        mtkView.framebufferOnly = false
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.preferredFramesPerSecond = 60
        mtkView.contentScaleFactor = UIScreen.main.nativeScale
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
        return mtkView
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.settings = settings
        context.coordinator.recorder = recorder
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        let device: MTLDevice?
        private var commandQueue: MTLCommandQueue?
        private var pipelineState: MTLRenderPipelineState?
        private var textureCache: CVMetalTextureCache?

        let cameraManager: SpatialCameraManager
        var settings: CalibrationSettings
        var recorder: StereoVideoRecorder
        private var lastRecordTime: CFTimeInterval = 0

        init(cameraManager: SpatialCameraManager, settings: CalibrationSettings, recorder: StereoVideoRecorder) {
            self.cameraManager = cameraManager
            self.settings = settings
            self.recorder = recorder
            self.device = MTLCreateSystemDefaultDevice()
            super.init()
            setupMetal()
        }

        private func setupMetal() {
            guard let device = device else { return }
            commandQueue = device.makeCommandQueue()
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)

            guard let library = device.makeDefaultLibrary(),
                  let vtx = library.makeFunction(name: "lenticularVertex"),
                  let frag = library.makeFunction(name: "lenticularFragment") else { return }

            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vtx
            desc.fragmentFunction = frag
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipelineState = try? device.makeRenderPipelineState(descriptor: desc)
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let rpd = view.currentRenderPassDescriptor,
                  let pipelineState = pipelineState,
                  let commandQueue = commandQueue,
                  let textureCache = textureCache else { return }

            let pair = cameraManager.currentBuffers()
            guard let wideBuf = pair.wide, let ultraBuf = pair.ultra else { return }

            guard let wideTex = makeTexture(from: wideBuf, cache: textureCache),
                  let ultraTex = makeTexture(from: ultraBuf, cache: textureCache) else { return }

            guard let cmd = commandQueue.makeCommandBuffer() else { return }

            let wAspect = Float(wideTex.width) / max(1.0, Float(wideTex.height))
            let uAspect = Float(ultraTex.width) / max(1.0, Float(ultraTex.height))

            // 1. Passe de renderização da tela ao vivo (60 fps)
            if let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) {
                var uniforms = LenticularUniforms(
                    viewportWidth: Float(view.drawableSize.width),
                    viewportHeight: Float(view.drawableSize.height),
                    pitch: Float(settings.pitch),
                    angleDeg: Float(settings.angleDeg),
                    offset: Float(settings.offset),
                    guardPct: Float(settings.guardPct),
                    swapEyes: settings.swapEyes ? 1.0 : 0.0,
                    orientHoriz: settings.orientHoriz ? 1.0 : 0.0,
                    ultraZoom: Float(settings.ultraZoom),
                    convergeX: Float(settings.convergeX),
                    alignY: Float(settings.alignY),
                    viewMode: Float(settings.viewMode),
                    wideAspect: wAspect,
                    ultraAspect: uAspect,
                    aspectFitMode: settings.aspectFit ? 1.0 : 0.0
                )

                enc.setRenderPipelineState(pipelineState)
                enc.setFragmentTexture(wideTex, index: 0)
                enc.setFragmentTexture(ultraTex, index: 1)
                enc.setFragmentBytes(&uniforms, length: MemoryLayout<LenticularUniforms>.stride, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                enc.endEncoding()
            }

            // 2. Passe de gravação de vídeo 3D (Espacial SBS ou Anáglifo Dubois em 1920x1080 @ 30 fps)
            var recordedBuffer: CVPixelBuffer?
            if recorder.isRecording {
                let now = CACurrentMediaTime()
                if now - lastRecordTime >= (1.0 / 30.0) {
                    if let pb = recorder.allocateFrameBuffer(),
                       let recTex = makeTexture(from: pb, cache: textureCache) {
                        lastRecordTime = now
                        recordedBuffer = pb

                        let recPass = MTLRenderPassDescriptor()
                        recPass.colorAttachments[0].texture = recTex
                        recPass.colorAttachments[0].loadAction = .clear
                        recPass.colorAttachments[0].storeAction = .store
                        recPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

                        if let recEnc = cmd.makeRenderCommandEncoder(descriptor: recPass) {
                            var recUniforms = LenticularUniforms(
                                viewportWidth: Float(recTex.width),
                                viewportHeight: Float(recTex.height),
                                pitch: Float(settings.pitch),
                                angleDeg: Float(settings.angleDeg),
                                offset: Float(settings.offset),
                                guardPct: Float(settings.guardPct),
                                swapEyes: settings.swapEyes ? 1.0 : 0.0,
                                orientHoriz: settings.orientHoriz ? 1.0 : 0.0,
                                ultraZoom: Float(settings.ultraZoom),
                                convergeX: Float(settings.convergeX),
                                alignY: Float(settings.alignY),
                                viewMode: (settings.recordFormat == 0) ? 1.0 : 2.0,
                                wideAspect: wAspect,
                                ultraAspect: uAspect,
                                aspectFitMode: settings.aspectFit ? 1.0 : 0.0
                            )

                            recEnc.setRenderPipelineState(pipelineState)
                            recEnc.setFragmentTexture(wideTex, index: 0)
                            recEnc.setFragmentTexture(ultraTex, index: 1)
                            recEnc.setFragmentBytes(&recUniforms, length: MemoryLayout<LenticularUniforms>.stride, index: 0)
                            recEnc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                            recEnc.endEncoding()
                        }
                    }
                }
            }

            if let pbToAppend = recordedBuffer {
                let recRef = self.recorder
                cmd.addCompletedHandler { _ in
                    recRef.appendRenderedFrame(pbToAppend)
                }
            }

            cmd.present(drawable)
            cmd.commit()
        }

        private func makeTexture(from pixelBuffer: CVPixelBuffer, cache: CVMetalTextureCache) -> MTLTexture? {
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            var cvTexOut: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                cache,
                pixelBuffer,
                nil,
                .bgra8Unorm,
                width,
                height,
                0,
                &cvTexOut
            )
            guard status == kCVReturnSuccess, let cvTex = cvTexOut else { return nil }
            return CVMetalTextureGetTexture(cvTex)
        }
    }
}

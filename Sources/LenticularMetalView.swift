import SwiftUI
import Metal
import MetalKit
import CoreVideo

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
}

struct LenticularMetalView: UIViewRepresentable {
    let cameraManager: SpatialCameraManager
    @ObservedObject var settings: CalibrationSettings

    func makeCoordinator() -> Coordinator {
        Coordinator(cameraManager: cameraManager, settings: settings)
    }

    func makeUIView(context: Context) -> MTKView {
        let mtkView = MTKView(frame: .zero, device: context.coordinator.device)
        mtkView.delegate = context.coordinator
        mtkView.framebufferOnly = true
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.preferredFramesPerSecond = 60
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
        mtkView.contentScaleFactor = UIScreen.main.nativeScale
        mtkView.clearColor = MTLClearColor(red: 0.015, green: 0.03, blue: 0.07, alpha: 1.0)
        return mtkView
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        let scale = UIScreen.main.nativeScale
        if uiView.contentScaleFactor != scale {
            uiView.contentScaleFactor = scale
        }
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        let device: MTLDevice?
        private let commandQueue: MTLCommandQueue?
        private var pipelineState: MTLRenderPipelineState?
        private var textureCache: CVMetalTextureCache?
        private var fallbackTexture: MTLTexture?

        private let cameraManager: SpatialCameraManager
        private let settings: CalibrationSettings

        init(cameraManager: SpatialCameraManager, settings: CalibrationSettings) {
            self.cameraManager = cameraManager
            self.settings = settings
            let dev = MTLCreateSystemDefaultDevice()
            self.device = dev
            self.commandQueue = dev?.makeCommandQueue()
            super.init()

            guard let dev = dev else { return }
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &textureCache)
            setupPipeline(device: dev)
            setupFallbackTexture(device: dev)
        }

        private func setupPipeline(device: MTLDevice) {
            guard let library = device.makeDefaultLibrary(),
                  let vfn = library.makeFunction(name: "vertex_fullscreen"),
                  let ffn = library.makeFunction(name: "fragment_lenticular") else {
                return
            }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vfn
            desc.fragmentFunction = ffn
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipelineState = try? device.makeRenderPipelineState(descriptor: desc)
        }

        private func setupFallbackTexture(device: MTLDevice) {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: 2,
                height: 2,
                mipmapped: false
            )
            desc.usage = [.shaderRead]
            if let tex = device.makeTexture(descriptor: desc) {
                var black = [UInt8](repeating: 0, count: 16)
                for i in stride(from: 3, to: 16, by: 4) { black[i] = 255 }
                tex.replace(
                    region: MTLRegionMake2D(0, 0, 2, 2),
                    mipmapLevel: 0,
                    withBytes: black,
                    bytesPerRow: 8
                )
                fallbackTexture = tex
            }
        }

        private func makeTexture(from pixelBuffer: CVPixelBuffer?) -> (tex: MTLTexture?, aspect: Float) {
            guard let pb = pixelBuffer, let cache = textureCache else {
                return (fallbackTexture, 1.333)
            }
            let w = CVPixelBufferGetWidth(pb)
            let h = CVPixelBufferGetHeight(pb)
            guard w > 0 && h > 0 else {
                return (fallbackTexture, 1.333)
            }
            var cvTexOut: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                cache,
                pb,
                nil,
                .bgra8Unorm,
                w,
                h,
                0,
                &cvTexOut
            )
            if status == kCVReturnSuccess, let cvTex = cvTexOut, let mtlTex = CVMetalTextureGetTexture(cvTex) {
                return (mtlTex, Float(w) / Float(h))
            }
            return (fallbackTexture, 1.333)
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let pipeline = pipelineState,
                  let queue = commandQueue,
                  let drawable = view.currentDrawable,
                  let rpd = view.currentRenderPassDescriptor,
                  let cmd = queue.makeCommandBuffer(),
                  let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else {
                return
            }

            let bufs = cameraManager.currentBuffers()
            let (wideTex, wideAspect) = makeTexture(from: bufs.wide)
            let (ultraTex, ultraAspect) = makeTexture(from: bufs.ultra)

            guard let tW = wideTex ?? fallbackTexture,
                  let tU = ultraTex ?? fallbackTexture else {
                enc.endEncoding()
                return
            }

            let dSize = view.drawableSize
            var uniforms = LenticularUniforms(
                viewportWidth: Float(max(1.0, dSize.width)),
                viewportHeight: Float(max(1.0, dSize.height)),
                pitch: settings.pitch,
                angleDeg: settings.angleDeg,
                offset: settings.offset,
                guardPct: settings.guardPct,
                swapEyes: settings.swapEyes ? 1.0 : 0.0,
                orientHoriz: settings.orientHoriz ? 1.0 : 0.0,
                ultraZoom: settings.ultraZoom,
                convergeX: settings.convergeX,
                alignY: settings.alignY,
                viewMode: Float(settings.viewMode),
                wideAspect: wideAspect,
                ultraAspect: ultraAspect
            )

            enc.setRenderPipelineState(pipeline)
            enc.setFragmentTexture(tW, index: 0)
            enc.setFragmentTexture(tU, index: 1)
            enc.setFragmentBytes(&uniforms, length: MemoryLayout<LenticularUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.endEncoding()

            cmd.present(drawable)
            cmd.commit()
        }
    }
}

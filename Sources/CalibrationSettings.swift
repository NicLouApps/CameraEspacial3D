import Foundation
import Combine

final class CalibrationSettings: ObservableObject {
    private static let storageKey = "camera_espacial_3d_settings_v2"

    struct Stored: Codable {
        var pitch: Float
        var angleDeg: Float
        var offset: Float
        var guardPct: Float
        var swapEyes: Bool
        var orientHoriz: Bool
        var ultraZoom: Float
        var convergeX: Float
        var alignY: Float
        var viewMode: Int
        var aspectFit: Bool
        var recordFormat: Int
    }

    private var isLoading = false

    @Published var pitch: Float = 6.116 { didSet { save() } }
    @Published var angleDeg: Float = 14.76 { didSet { save() } }
    @Published var offset: Float = 0.38 { didSet { save() } }
    @Published var guardPct: Float = 20.0 { didSet { save() } }
    @Published var swapEyes: Bool = true { didSet { save() } }
    @Published var orientHoriz: Bool = false { didSet { save() } }

    @Published var ultraZoom: Float = 1.92 { didSet { save() } }
    @Published var convergeX: Float = 0.0 { didSet { save() } }
    @Published var alignY: Float = 0.0 { didSet { save() } }
    // 0 = Lenticular 3D, 1 = SBS, 2 = Anaglifo Dubois
    @Published var viewMode: Int = 0 { didSet { save() } }
    // true = Proporcao Original da camera (sem cortar/esticar), false = Preencher Tela
    @Published var aspectFit: Bool = true { didSet { save() } }
    // 0 = Gravar Espacial 3D (SBS), 1 = Gravar Anaglifo Dubois
    @Published var recordFormat: Int = 0 { didSet { save() } }

    init() {
        load()
    }

    func resetDefaults() {
        isLoading = true
        pitch = 6.116
        angleDeg = 14.76
        offset = 0.38
        guardPct = 20.0
        swapEyes = true
        orientHoriz = false
        ultraZoom = 1.92
        convergeX = 0.0
        alignY = 0.0
        viewMode = 0
        aspectFit = true
        recordFormat = 0
        isLoading = false
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode(Stored.self, from: data) else {
            return
        }
        isLoading = true
        pitch = decoded.pitch
        angleDeg = decoded.angleDeg
        offset = decoded.offset
        guardPct = decoded.guardPct
        swapEyes = decoded.swapEyes
        orientHoriz = decoded.orientHoriz
        ultraZoom = decoded.ultraZoom
        convergeX = decoded.convergeX
        alignY = decoded.alignY
        viewMode = decoded.viewMode
        aspectFit = decoded.aspectFit
        recordFormat = decoded.recordFormat
        isLoading = false
    }

    private func save() {
        guard !isLoading else { return }
        let s = Stored(
            pitch: pitch,
            angleDeg: angleDeg,
            offset: offset,
            guardPct: guardPct,
            swapEyes: swapEyes,
            orientHoriz: orientHoriz,
            ultraZoom: ultraZoom,
            convergeX: convergeX,
            alignY: alignY,
            viewMode: viewMode,
            aspectFit: aspectFit,
            recordFormat: recordFormat
        )
        if let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

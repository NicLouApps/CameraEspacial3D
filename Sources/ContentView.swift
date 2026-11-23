import SwiftUI

struct ContentView: View {
    @StateObject private var cameraManager = SpatialCameraManager()
    @StateObject private var settings = CalibrationSettings()
    @State private var showControls = false

    var body: some View {
        ZStack {
            LenticularMetalView(cameraManager: cameraManager, settings: settings)
                .ignoresSafeArea()

            statusOverlay

            VStack {
                HStack {
                    Spacer()
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            showControls.toggle()
                        }
                    }) {
                        Text(showControls ? "FECHAR" : "CFG")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color(red: 0.03, green: 0.07, blue: 0.16).opacity(showControls ? 0.92 : 0.55))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.cyan.opacity(0.75), lineWidth: 1.5)
                            )
                            .cornerRadius(10)
                    }
                    .padding(.top, 10)
                    .padding(.trailing, 14)
                }

                Spacer()

                if showControls {
                    controlPanel
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            cameraManager.start()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            cameraManager.stop()
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch cameraManager.status {
        case .running, .starting:
            EmptyView()
        case .denied:
            statusCard(
                title: "Permissão de Câmera Necessária",
                message: "Ative o acesso à câmera em Ajustes > Privacidade > Câmera para visualizar o 3D ao vivo."
            )
        case .unsupported(let msg):
            statusCard(title: "MultiCam Indisponível", message: msg)
        case .error(let msg):
            statusCard(title: "Erro nas Câmeras", message: msg)
        }
    }

    private func statusCard(title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.cyan)
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
        }
        .padding(18)
        .background(Color(red: 0.04, green: 0.08, blue: 0.18).opacity(0.92))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.cyan.opacity(0.7), lineWidth: 1.5)
        )
        .cornerRadius(16)
        .padding(24)
    }

    private var controlPanel: some View {
        ScrollView {
            VStack(spacing: 10) {
                // Modo de visualizacao
                HStack(spacing: 6) {
                    modeButton(title: "3D LENTICULAR", mode: 0)
                    modeButton(title: "SBS", mode: 1)
                    modeButton(title: "ANÁGLIFO", mode: 2)
                }

                // Alinhamento das duas lentes (Wide 1x + Ultra-Wide 0.5x)
                VStack(spacing: 6) {
                    sliderRow(
                        label: "ZOOM ULTRA-WIDE",
                        valueText: String(format: "%.2fx", settings.ultraZoom),
                        value: $settings.ultraZoom,
                        range: 1.40...2.40,
                        step: 0.01
                    )
                    sliderRow(
                        label: "CONVERGÊNCIA 3D (X)",
                        valueText: String(format: "%+.1f%%", settings.convergeX * 100),
                        value: $settings.convergeX,
                        range: -0.15...0.15,
                        step: 0.002
                    )
                    sliderRow(
                        label: "ALINHAMENTO VERTICAL (Y)",
                        valueText: String(format: "%+.1f%%", settings.alignY * 100),
                        value: $settings.alignY,
                        range: -0.12...0.12,
                        step: 0.002
                    )
                }
                .padding(8)
                .background(Color.white.opacity(0.05))
                .cornerRadius(10)

                // Calibracao Lenticular (75 LPI pre-carregada)
                VStack(spacing: 6) {
                    HStack {
                        Text("PITCH: \(String(format: "%.3f", settings.pitch))")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.cyan)
                        Spacer()
                        stepButton("-0.01") { settings.pitch = max(2.0, settings.pitch - 0.01) }
                        stepButton("-0.001") { settings.pitch = max(2.0, settings.pitch - 0.001) }
                        stepButton("+0.001") { settings.pitch = min(11.0, settings.pitch + 0.001) }
                        stepButton("+0.01") { settings.pitch = min(11.0, settings.pitch + 0.01) }
                    }
                    Slider(value: $settings.pitch, in: 5.20...7.20)
                        .tint(.cyan)

                    HStack {
                        Text("ÂNGULO: \(String(format: "%.2f°", settings.angleDeg))")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.cyan)
                        Spacer()
                        stepButton("-0.2°") { settings.angleDeg = max(-30, settings.angleDeg - 0.2) }
                        stepButton("-0.02°") { settings.angleDeg = max(-30, settings.angleDeg - 0.02) }
                        stepButton("+0.02°") { settings.angleDeg = min(30, settings.angleDeg + 0.02) }
                        stepButton("+0.2°") { settings.angleDeg = min(30, settings.angleDeg + 0.2) }
                    }
                    Slider(value: $settings.angleDeg, in: -30.0...30.0)
                        .tint(.cyan)

                    sliderRow(
                        label: "FASE (OFFSET)",
                        valueText: String(format: "%.2f", settings.offset),
                        value: $settings.offset,
                        range: 0.0...1.0,
                        step: 0.01
                    )
                    sliderRow(
                        label: "ANTI-FANTASMA",
                        valueText: "\(Int(settings.guardPct))%",
                        value: $settings.guardPct,
                        range: 0.0...45.0,
                        step: 1.0
                    )
                }
                .padding(8)
                .background(Color.white.opacity(0.05))
                .cornerRadius(10)

                // Botoes rapidos
                HStack(spacing: 6) {
                    toggleButton(
                        title: settings.swapEyes ? "INV E/D: ON" : "INV E/D: OFF",
                        active: settings.swapEyes
                    ) {
                        settings.swapEyes.toggle()
                    }
                    toggleButton(
                        title: settings.orientHoriz ? "LINHAS: HORIZ" : "LINHAS: VERT",
                        active: settings.orientHoriz
                    ) {
                        settings.orientHoriz.toggle()
                    }
                    Button(action: { settings.resetDefaults() }) {
                        Text("RESET 75 LPI")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.red.opacity(0.35))
                            .cornerRadius(8)
                    }
                }
            }
            .padding(12)
        }
        .frame(maxWidth: 520, maxHeight: 330)
        .background(Color(red: 0.03, green: 0.06, blue: 0.14).opacity(0.90))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.cyan.opacity(0.55), lineWidth: 1.5)
        )
        .cornerRadius(16)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func modeButton(title: String, mode: Int) -> some View {
        let active = settings.viewMode == mode
        return Button(action: { settings.viewMode = mode }) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(active ? Color.cyan.opacity(0.35) : Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(active ? Color.cyan : Color.clear, lineWidth: 1.5)
                )
                .cornerRadius(8)
        }
    }

    private func stepButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.14))
                .cornerRadius(6)
        }
    }

    private func toggleButton(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(active ? Color.orange.opacity(0.35) : Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(active ? Color.orange : Color.white.opacity(0.2), lineWidth: 1)
                )
                .cornerRadius(8)
        }
    }

    private func sliderRow(label: String,
                           valueText: String,
                           value: Binding<Float>,
                           range: ClosedRange<Float>,
                           step: Float) -> some View {
        VStack(spacing: 2) {
            HStack {
                Text(label)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundColor(Color(red: 0.72, green: 0.85, blue: 0.98))
                Spacer()
                Text(valueText)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.cyan)
            }
            Slider(value: value, in: range, step: step)
                .tint(.cyan)
        }
    }
}

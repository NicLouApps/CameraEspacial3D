import SwiftUI

struct ContentView: View {
    @StateObject private var cameraManager = SpatialCameraManager()
    @StateObject private var settings = CalibrationSettings()
    @StateObject private var recorder = StereoVideoRecorder()
    @State private var showControls = false

    private func formatDuration(_ sec: Int) -> String {
        let m = sec / 60
        let s = sec % 60
        return String(format: "%02d:%02d", m, s)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            LenticularMetalView(cameraManager: cameraManager, settings: settings, recorder: recorder)
                .ignoresSafeArea()
                .onTapGesture(count: 2) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showControls.toggle()
                    }
                }

            // Aviso visual caso a câmera apresente erro ou falta de permissão
            switch cameraManager.status {
            case .denied:
                statusBanner("Acesso à câmera negado. Ative em Ajustes > Privacidade > Câmera.")
            case .unsupported(let msg), .error(let msg):
                statusBanner(msg)
            default:
                EmptyView()
            }

            VStack(spacing: 8) {
                // Barra Superior Compacta
                HStack(spacing: 6) {
                    // Seletor de Formato de Gravação (Espacial 3D SBS vs Anáglifo Dubois)
                    Button(action: {
                        if !recorder.isRecording {
                            settings.recordFormat = (settings.recordFormat == 0) ? 1 : 0
                        }
                    }) {
                        Text(settings.recordFormat == 0 ? "GRAVAR: ESPACIAL 3D" : "GRAVAR: DUBOIS")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(settings.recordFormat == 0 ? .cyan : .orange)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 7)
                            .background(Color.black.opacity(0.68))
                            .overlay(
                                Capsule().stroke(settings.recordFormat == 0 ? Color.cyan.opacity(0.55) : Color.orange.opacity(0.65), lineWidth: 1)
                            )
                            .clipShape(Capsule())
                    }
                    .disabled(recorder.isRecording)

                    // Botão de Gravar / Parar Vídeo
                    Button(action: {
                        let fmtName = (settings.recordFormat == 0) ? "Espacial 3D (SBS)" : "Anáglifo Dubois"
                        recorder.toggleRecording(formatName: fmtName)
                    }) {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Color.white)
                                .frame(width: 7, height: 7)
                            Text(recorder.isRecording ? "PARAR \(formatDuration(recorder.recordedSeconds))" : "GRAVAR")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(recorder.isRecording ? Color.red : Color.red.opacity(0.82))
                        .overlay(
                            Capsule().stroke(Color.white.opacity(0.45), lineWidth: 1)
                        )
                        .clipShape(Capsule())
                    }

                    Spacer()

                    // Alternador Rápido de Proporção da Câmera (Proporção Real vs Preencher Tela)
                    Button(action: {
                        settings.aspectFit.toggle()
                    }) {
                        Text(settings.aspectFit ? "PROP. REAL" : "TELA CHEIA")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(settings.aspectFit ? .green : .white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 7)
                            .background(Color.black.opacity(0.68))
                            .overlay(
                                Capsule().stroke(settings.aspectFit ? Color.green.opacity(0.55) : Color.white.opacity(0.25), lineWidth: 1)
                            )
                            .clipShape(Capsule())
                    }

                    // Botão de Painel de Calibração e Ajustes
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showControls.toggle()
                        }
                    }) {
                        Text(showControls ? "FECHAR" : "CFG")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.cyan)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7)
                            .background(Color.black.opacity(0.68))
                            .overlay(
                                Capsule().stroke(Color.cyan.opacity(0.5), lineWidth: 1)
                            )
                            .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)

                // Toast de Status da Gravação
                if let toast = recorder.toastMessage {
                    Text(toast)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color.black.opacity(0.82))
                        .overlay(
                            Capsule().stroke(Color.cyan.opacity(0.6), lineWidth: 1)
                        )
                        .clipShape(Capsule())
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

    private var controlPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("CALIBRAÇÃO 3D & GRAVAÇÃO • v1.2")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.cyan)
                    Spacer()
                    Button("RESET 75 LPI") {
                        settings.resetDefaults()
                    }
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.15))
                    .clipShape(Capsule())
                }

                // Seletor de Modo de Visualização Ao Vivo
                VStack(alignment: .leading, spacing: 4) {
                    Text("VISUALIZAÇÃO AO VIVO NA TELA:")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.gray)
                    HStack(spacing: 6) {
                        modeButton(title: "3D LENTICULAR", mode: 0)
                        modeButton(title: "ESPACIAL SBS", mode: 1)
                        modeButton(title: "ANÁGLIFO DUBOIS", mode: 2)
                    }
                }

                // Seletor de Formato de Gravação de Vídeo
                VStack(alignment: .leading, spacing: 4) {
                    Text("FORMATO DO VÍDEO GRAVADO (1080p 30FPS • FOTOS):")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.gray)
                    HStack(spacing: 6) {
                        recordFormatButton(title: "VÍDEO ESPACIAL 3D (SBS)", format: 0)
                        recordFormatButton(title: "VÍDEO ANÁGLIFO DUBOIS", format: 1)
                    }
                }

                // Proporção da Imagem
                HStack(spacing: 8) {
                    toggleButton(title: "PROPORÇÃO REAL (SEM ESTICAR)", isOn: $settings.aspectFit)
                }

                // Sliders Lenticulares (Pitch, Ângulo, Fase, Anti-Fantasma)
                sliderRow(
                    title: "PITCH (PX/LENTE)",
                    value: $settings.pitch,
                    range: 3.0...12.0,
                    step: 0.001,
                    format: "%.3f"
                )

                sliderRow(
                    title: "ÂNGULO (°)",
                    value: $settings.angleDeg,
                    range: -35.0...35.0,
                    step: 0.01,
                    format: "%.2f°"
                )

                sliderRow(
                    title: "FASE (OFFSET)",
                    value: $settings.offset,
                    range: 0.0...1.0,
                    step: 0.01,
                    format: "%.2f"
                )

                sliderRow(
                    title: "ANTI-FANTASMA",
                    value: $settings.guardPct,
                    range: 0.0...45.0,
                    step: 1.0,
                    format: "%.0f%%"
                )

                Divider().background(Color.white.opacity(0.2))

                // Alinhamento Óptico entre Lente Principal (24mm) e Ultra-Wide (13mm)
                sliderRow(
                    title: "ZOOM ULTRA-WIDE (CASAR FOV 24MM)",
                    value: $settings.ultraZoom,
                    range: 1.20...2.60,
                    step: 0.01,
                    format: "%.2fx"
                )

                sliderRow(
                    title: "CONVERGÊNCIA 3D (PARALAXE H)",
                    value: $settings.convergeX,
                    range: -0.25...0.25,
                    step: 0.002,
                    format: "%+.3f"
                )

                sliderRow(
                    title: "ALINHAMENTO VERTICAL (Y)",
                    value: $settings.alignY,
                    range: -0.20...0.20,
                    step: 0.002,
                    format: "%+.3f"
                )

                HStack(spacing: 8) {
                    toggleButton(title: "INV E/D", isOn: $settings.swapEyes)
                    toggleButton(title: "LINHAS HORIZ", isOn: $settings.orientHoriz)
                }
            }
            .padding(14)
        }
        .frame(maxHeight: 340)
        .background(Color(red: 0.03, green: 0.06, blue: 0.11).opacity(0.90))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.cyan.opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func statusBanner(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            .padding(14)
            .background(Color.red.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(24)
    }

    private func modeButton(title: String, mode: Int) -> some View {
        Button(action: { settings.viewMode = mode }) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(settings.viewMode == mode ? .black : .white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(settings.viewMode == mode ? Color.cyan : Color.white.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func recordFormatButton(title: String, format: Int) -> some View {
        Button(action: {
            if !recorder.isRecording {
                settings.recordFormat = format
            }
        }) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(settings.recordFormat == format ? .black : .white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(settings.recordFormat == format ? Color.orange : Color.white.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .disabled(recorder.isRecording)
    }

    private func toggleButton(title: String, isOn: Binding<Bool>) -> some View {
        Button(action: { isOn.wrappedValue.toggle() }) {
            Text("\(title): \(isOn.wrappedValue ? "ON" : "OFF")")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(isOn.wrappedValue ? .black : .white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(isOn.wrappedValue ? Color.orange : Color.white.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func sliderRow(
        title: String,
        value: Binding<Float>,
        range: ClosedRange<Float>,
        step: Float,
        format: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.gray)
                Spacer()
                Button("-1") {
                    value.wrappedValue = max(range.lowerBound, value.wrappedValue - step)
                }
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.cyan)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.white.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 4))

                Text(String(format: format, value.wrappedValue))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.cyan)
                    .frame(minWidth: 58, alignment: .trailing)

                Button("+1") {
                    value.wrappedValue = min(range.upperBound, value.wrappedValue + step)
                }
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.cyan)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.white.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            Slider(value: value, in: range)
                .tint(.cyan)
        }
    }
}

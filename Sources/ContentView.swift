import SwiftUI

struct ContentView: View {
    @StateObject private var cameraManager = SpatialCameraManager()
    @StateObject private var settings = CalibrationSettings()
    @StateObject private var recorder = StereoVideoRecorder()
    @State private var showControls = false

    // Paleta Design System (Linear / Vercel / Apple Pro)
    private let bgSurface = Color(red: 0.078, green: 0.078, blue: 0.078)       // #141414
    private let cardLight = Color.white                                        // #FFFFFF
    private let textPrimaryDark = Color(red: 0.090, green: 0.090, blue: 0.090) // #171717
    private let textMuted = Color(red: 0.451, green: 0.451, blue: 0.451)       // #737373
    private let borderSubtle = Color(red: 0.898, green: 0.898, blue: 0.898)    // #E5E5E5
    private let pillDark = Color(red: 0.12, green: 0.12, blue: 0.12)           // #1F1F1F
    private let borderDark = Color(red: 0.22, green: 0.22, blue: 0.22)         // #383838

    private func formatDuration(_ sec: Int) -> String {
        let m = sec / 60
        let s = sec % 60
        return String(format: "%02d:%02d", m, s)
    }

    private var hasActiveCameraFrames: Bool {
        let pair = cameraManager.currentBuffers()
        return pair.wide != nil && pair.ultra != nil
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            LenticularMetalView(cameraManager: cameraManager, settings: settings, recorder: recorder)
                .ignoresSafeArea()
                .onTapGesture(count: 2) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showControls.toggle()
                    }
                }

            // Status / Diagnóstico da Câmera
            switch cameraManager.status {
            case .starting:
                statusCard(icon: "camera.aperture", title: "Iniciando câmeras 3D...", isError: false)
            case .denied:
                statusCard(icon: "lock.fill", title: "Acesso à câmera negado. Ative em Ajustes > Privacidade > Câmera.", isError: true)
            case .unsupported(let msg), .error(let msg):
                statusCard(icon: "exclamationmark.triangle.fill", title: msg, isError: true)
            case .running:
                EmptyView()
            }

            VStack(spacing: 10) {
                topToolbar

                if let toast = recorder.toastMessage {
                    toastBanner(toast)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Spacer()

                if showControls {
                    settingsDrawer
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
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

    // MARK: - Top Minimalist Toolbar (#141414 surface, clean icons + concise labels)
    private var topToolbar: some View {
        HStack(spacing: 8) {
            // Seletor de formato de gravação
            Button(action: {
                if !recorder.isRecording {
                    settings.recordFormat = (settings.recordFormat == 0) ? 1 : 0
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: settings.recordFormat == 0 ? "square.split.2x1" : "eyeglasses")
                        .font(.system(size: 12, weight: .semibold))
                    Text(settings.recordFormat == 0 ? "SBS 3D" : "Dubois")
                        .font(.system(size: 12, weight: .semibold, design: .default))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(bgSurface.opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(borderDark, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .disabled(recorder.isRecording)
            .accessibilityLabel("Alternar formato de gravação entre Espacial SBS 3D e Anáglifo Dubois")

            // Botão Principal de Gravação (Destaque funcional)
            Button(action: {
                let fmtName = (settings.recordFormat == 0) ? "Espacial 3D" : "Anáglifo Dubois"
                recorder.toggleRecording(formatName: fmtName, hasCameraSignal: hasActiveCameraFrames)
            }) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(recorder.isRecording ? Color.red : Color(red: 0.88, green: 0.18, blue: 0.18))
                        .frame(width: 8, height: 8)
                    Text(recorder.isRecording ? formatDuration(recorder.recordedSeconds) : "Gravar")
                        .font(.system(size: 12, weight: .semibold, design: .default))
                        .foregroundColor(recorder.isRecording ? .white : textPrimaryDark)
                }
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(recorder.isRecording ? Color(red: 0.78, green: 0.12, blue: 0.12) : cardLight)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(recorder.isRecording ? Color.red.opacity(0.6) : borderSubtle, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .accessibilityLabel(recorder.isRecording ? "Parar gravação" : "Iniciar gravação de vídeo 3D")

            Spacer()

            // Modo de Visualização Ao Vivo (Ciclo rápido: Lenticular -> SBS -> Dubois)
            Button(action: {
                settings.viewMode = (settings.viewMode + 1) % 3
            }) {
                HStack(spacing: 6) {
                    Image(systemName: viewModeIcon(settings.viewMode))
                        .font(.system(size: 12, weight: .semibold))
                    Text(viewModeShortTitle(settings.viewMode))
                        .font(.system(size: 12, weight: .medium, design: .default))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(bgSurface.opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(borderDark, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .accessibilityLabel("Modo de visualização ao vivo")

            // Alternador de Proporção Real (4:3) vs Tela Cheia
            Button(action: {
                settings.aspectFit.toggle()
            }) {
                HStack(spacing: 5) {
                    Image(systemName: settings.aspectFit ? "aspectratio" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12, weight: .semibold))
                    Text(settings.aspectFit ? "4:3" : "Cheia")
                        .font(.system(size: 12, weight: .medium, design: .default))
                }
                .foregroundColor(settings.aspectFit ? textPrimaryDark : .white)
                .padding(.horizontal, 11)
                .frame(height: 36)
                .background(settings.aspectFit ? cardLight : bgSurface.opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(settings.aspectFit ? borderSubtle : borderDark, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .accessibilityLabel("Alternar proporção real 4:3 ou tela cheia")

            // Botão Rápido para Girar 90° a Imagem (caso o bloqueio de rotação do iPhone esteja ativo)
            Button(action: {
                cameraManager.rotate90Clockwise()
            }) {
                Image(systemName: "rotate.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(bgSurface.opacity(0.92))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(borderDark, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .accessibilityLabel("Girar imagem da câmera em 90 graus")

            // Botão de Ajustes / Calibração
            Button(action: {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showControls.toggle()
                }
            }) {
                Image(systemName: showControls ? "xmark" : "slider.horizontal.3")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(showControls ? textPrimaryDark : .white)
                    .frame(width: 36, height: 36)
                    .background(showControls ? cardLight : bgSurface.opacity(0.92))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(showControls ? borderSubtle : borderDark, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .accessibilityLabel(showControls ? "Fechar ajustes" : "Abrir ajustes de calibração")
        }
    }

    // MARK: - Painel de Calibração Profissional (Padrão Linear / Apple)
    private var settingsDrawer: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Cabeçalho limpo
            HStack {
                Text("Calibração & Óptica 3D")
                    .font(.system(size: 13, weight: .semibold, design: .default))
                    .foregroundColor(.white)

                Text("v1.4")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(textMuted)

                Spacer()

                Button(action: {
                    settings.resetDefaults()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Padrão 75 LPI")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(pillDark)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(borderDark, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }

            Divider().background(borderDark)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 14) {
                    // Linha 1: Visualização & Gravação em Grid de 2 Colunas
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            sectionLabel("VISUALIZAÇÃO AO VIVO")
                            HStack(spacing: 6) {
                                segmentButton(title: "Lenticular", selected: settings.viewMode == 0) {
                                    settings.viewMode = 0
                                }
                                segmentButton(title: "SBS 3D", selected: settings.viewMode == 1) {
                                    settings.viewMode = 1
                                }
                                segmentButton(title: "Dubois", selected: settings.viewMode == 2) {
                                    settings.viewMode = 2
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            sectionLabel("FORMATO DE GRAVAÇÃO")
                            HStack(spacing: 6) {
                                segmentButton(title: "Espacial SBS", selected: settings.recordFormat == 0) {
                                    if !recorder.isRecording { settings.recordFormat = 0 }
                                }
                                segmentButton(title: "Anáglifo Dubois", selected: settings.recordFormat == 1) {
                                    if !recorder.isRecording { settings.recordFormat = 1 }
                                }
                            }
                        }
                    }

                    // Linha 2: Opções Rápidas (Proporção, Inverter E/D, Eixo)
                    HStack(spacing: 8) {
                        togglePill(icon: "aspectratio", title: "Proporção Original", isOn: $settings.aspectFit)
                        togglePill(icon: "arrow.left.arrow.right", title: "Inverter Olhos", isOn: $settings.swapEyes)
                        togglePill(icon: "line.3.horizontal", title: "Eixo Horizontal", isOn: $settings.orientHoriz)
                    }

                    Divider().background(borderDark)

                    // Grade de Parâmetros (2 colunas para aproveitar largura sem poluir)
                    VStack(spacing: 12) {
                        HStack(spacing: 16) {
                            sliderControl(
                                title: "Pitch (px/lente)",
                                value: $settings.pitch,
                                range: 3.0...12.0,
                                step: 0.001,
                                format: "%.3f"
                            )
                            sliderControl(
                                title: "Inclinação (°)",
                                value: $settings.angleDeg,
                                range: -35.0...35.0,
                                step: 0.01,
                                format: "%.2f°"
                            )
                        }

                        HStack(spacing: 16) {
                            sliderControl(
                                title: "Fase (Offset)",
                                value: $settings.offset,
                                range: 0.0...1.0,
                                step: 0.01,
                                format: "%.2f"
                            )
                            sliderControl(
                                title: "Anti-Fantasma",
                                value: $settings.guardPct,
                                range: 0.0...45.0,
                                step: 1.0,
                                format: "%.0f%%"
                            )
                        }

                        HStack(spacing: 16) {
                            sliderControl(
                                title: "Zoom Ultra-Wide",
                                value: $settings.ultraZoom,
                                range: 1.20...2.60,
                                step: 0.01,
                                format: "%.2fx"
                            )
                            sliderControl(
                                title: "Convergência H",
                                value: $settings.convergeX,
                                range: -0.25...0.25,
                                step: 0.002,
                                format: "%+.3f"
                            )
                        }

                        HStack(spacing: 16) {
                            sliderControl(
                                title: "Alinhamento Vertical",
                                value: $settings.alignY,
                                range: -0.20...0.20,
                                step: 0.002,
                                format: "%+.3f"
                            )
                            Spacer().frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 230)
        }
        .padding(16)
        .background(bgSurface.opacity(0.96))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(borderDark, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Subcomponentes do Design System
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .default))
            .foregroundColor(textMuted)
            .tracking(0.4)
    }

    private func segmentButton(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: selected ? .semibold : .medium, design: .default))
                .foregroundColor(selected ? textPrimaryDark : .white)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(selected ? cardLight : pillDark)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(selected ? borderSubtle : borderDark, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func togglePill(icon: String, title: String, isOn: Binding<Bool>) -> some View {
        Button(action: { isOn.wrappedValue.toggle() }) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .medium, design: .default))
                    .lineLimit(1)
            }
            .foregroundColor(isOn.wrappedValue ? textPrimaryDark : .white)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background(isOn.wrappedValue ? cardLight : pillDark)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isOn.wrappedValue ? borderSubtle : borderDark, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func sliderControl(
        title: String,
        value: Binding<Float>,
        range: ClosedRange<Float>,
        step: Float,
        format: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .medium, design: .default))
                    .foregroundColor(Color(white: 0.82))
                    .lineLimit(1)

                Spacer()

                Button(action: {
                    value.wrappedValue = max(range.lowerBound, value.wrappedValue - step)
                }) {
                    Image(systemName: "minus")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 22, height: 22)
                        .background(pillDark)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(borderDark, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                Text(String(format: format, value.wrappedValue))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .frame(minWidth: 52, alignment: .trailing)

                Button(action: {
                    value.wrappedValue = min(range.upperBound, value.wrappedValue + step)
                }) {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 22, height: 22)
                        .background(pillDark)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(borderDark, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            Slider(value: value, in: range)
                .tint(.white)
        }
        .frame(maxWidth: .infinity)
    }

    private func toastBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(textPrimaryDark)
            Text(message)
                .font(.system(size: 12, weight: .medium, design: .default))
                .foregroundColor(textPrimaryDark)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(cardLight)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(borderSubtle, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func statusCard(icon: String, title: String, isError: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(isError ? .white : textPrimaryDark)
            Text(title)
                .font(.system(size: 12, weight: .medium, design: .default))
                .foregroundColor(isError ? .white : textPrimaryDark)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(isError ? Color(red: 0.75, green: 0.14, blue: 0.14) : cardLight)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isError ? Color.red.opacity(0.5) : borderSubtle, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(24)
    }

    private func viewModeShortTitle(_ mode: Int) -> String {
        switch mode {
        case 1: return "Vivo: SBS"
        case 2: return "Vivo: Dubois"
        default: return "Vivo: 3D"
        }
    }

    private func viewModeIcon(_ mode: Int) -> String {
        switch mode {
        case 1: return "rectangle.split.2x1"
        case 2: return "eyeglasses"
        default: return "sparkles.tv"
        }
    }
}

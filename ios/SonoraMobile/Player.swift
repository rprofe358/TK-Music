import SwiftUI

/// Lo que se ve en el centro del reproductor en vez de la portada.
private enum PlayerPanel {
    case lyrics, queue, session
}

/// El reproductor a pantalla completa, sobre la portada desenfocada. En el centro se turnan la
/// portada, la letra, la cola y la sesión; se cierra con la flecha o deslizando hacia abajo.
struct PlayerView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openRoute) private var open
    @State private var panel: PlayerPanel?
    @State private var scrub: Double?
    @State private var volume: Double = 1
    @State private var adding = false
    @State private var playlist: PendingAdd?
    @State private var drag: CGFloat = 0
    /// La portada es clara: texto e iconos casi negros en vez de blancos.
    @State private var light = false
    /// Pantalla completa, como en el escritorio, y si sus controles se ven ahora.
    @State private var stage = false
    @State private var stageShown = true
    /// Cambia con cada toque en la pantalla completa, para volver a contar hasta esconder.
    @State private var stagePoke = 0
    /// El color más vivo de la portada, para la onda de la pantalla completa.
    @State private var stageGlow: Color?
    /// El segundo color de la portada, para la onda de atrás.
    @State private var stageDepth: Color?
    /// La música como números, para los visuales.
    @State private var spectrum = Spectrum()
    /// Dónde está la portada de la pantalla completa en la pantalla, para dibujar los visuales
    /// alrededor de ella.
    @State private var coverFrame: CGRect = .zero
    /// Desde cuándo está abierta la pantalla completa, para el giro del Vinilo.
    @State private var stageStart = Date()
    /// Lo que se tocó en el corazón, mientras el servicio lo confirma.

    private var fg: Color { light ? Color(white: 0.08) : .white }

    var body: some View {
        let state = store.state
        GeometryReader { geometry in
            if stage {
                stageView(state, size: geometry.size)
            } else if geometry.size.width > geometry.size.height || geometry.size.width >= 700 {
                // de lado, o en una pantalla ancha (iPad): dos columnas
                landscape(state, size: geometry.size)
            } else {
                portrait(state)
            }
        }
        .background {
            ZStack {
                Backdrop(url: state.track?.cover, light: $light)
            }
        }
        // los colores de la portada, para resaltar la letra y para las ondas
        .environment(\.lyricAccent, LyricAccent(glow: stageGlow ?? fg, depth: stageDepth ?? stageGlow ?? fg))
        .task(id: state.track?.cover) {
            guard let url = state.track?.cover else { return }
            let image = await ImagePipeline.shared.image(url)
            let colors = image?.vividColors ?? []
            withAnimation(.easeInOut(duration: 0.8)) {
                stageGlow = colors.first
                stageDepth = colors.dropFirst().first
            }
        }
        .offset(y: drag)
        .foregroundStyle(fg)
        .environment(\.colorScheme, light ? .light : .dark)
        .tint(fg)
        .animation(.easeInOut(duration: 0.5), value: light)
        .onChange(of: state.track == nil) { gone in
            if gone { dismiss() }
        }
        .sheet(isPresented: $adding) {
            AddSongsView(slug: state.provider ?? store.selected).environmentObject(store)
        }
        .sheet(item: $playlist) { adding in
            PlaylistPicker(adding: adding).environmentObject(store)
        }
        .sheet(item: $store.sharing) { target in
            ShareSheet(target: target).environmentObject(store)
        }
        .alert(
            "Aviso",
            isPresented: Binding(
                get: { store.problem != nil },
                set: { if !$0 { store.problem = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.problem ?? "")
        }
    }

    // MARK: Partes

    private func portrait(_ state: PlaybackState) -> some View {
        VStack(spacing: 14) {
            header(state)
                .gesture(dismissDrag)
            center(state)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let track = state.track {
                info(track, slug: state.provider ?? store.selected)
            }
            VisualizerView(color: fg).frame(height: 32)
            seek(state)
            controls(state)
            remoteNote(state)
            toggles
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 8)
    }

    /// De lado: portada y controles a la izquierda, letra (o cola, o sesión) a la derecha.
    private func landscape(_ state: PlaybackState, size: CGSize) -> some View {
        let height = size.height
        return HStack(spacing: 24) {
            ScrollView {
                VStack(spacing: 10) {
                    Cover(
                        url: state.coverLarge ?? state.track?.cover,
                        // lo que dejan el título, la barra y los botones, para que todo quepa
                        size: max(90, min(height * 0.45, height - 270, size.width * 0.4)),
                        fallback: state.track?.cover
                    )
                    .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
                    if let track = state.track {
                        info(track, slug: state.provider ?? store.selected)
                    }
                    VisualizerView(color: fg).frame(height: 24)
                    seek(state)
                    controls(state)
                    remoteNote(state)
                }
                .padding(.vertical, 12)
                // centrado en la altura, con aire arriba y abajo
                .frame(minHeight: height, alignment: .center)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity)
            VStack(spacing: 8) {
                header(state)
                    .gesture(dismissDrag)
                Group {
                    switch panel ?? .lyrics {
                    case .queue: QueuePanel { adding = true }
                    case .session: SessionList(slug: state.provider).scrollContentBackground(.hidden)
                    default: LyricsPanel()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                toggles
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
    }

    private func header(_ state: PlaybackState) -> some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            Spacer()
            Text(providerName(state.provider).map { "Reproduciendo desde \($0)" } ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                stagePoke += 1
                withAnimation(.easeInOut(duration: 0.3)) { stage = true }
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Pantalla completa")
            menu(state)
        }
        .foregroundStyle(fg)
        .contentShape(Rectangle())
    }

    /// Pantalla completa, como en el escritorio: la portada en el centro sobre el fondo
    /// desenfocado, una onda luminosa del color de la portada a lo ancho del borde de abajo y los
    /// controles, que se esconden solos. Al mostrarlos, la portada les hace sitio: se corre a la
    /// izquierda con la pantalla de lado, y hacia arriba de pie. Un toque los vuelve a mostrar.
    private func stageView(_ state: PlaybackState, size: CGSize) -> some View {
        let landscape = size.width > size.height
        let cover = max(120, landscape
            ? min(size.width * 0.34, size.height * 0.5)
            : min(size.width * 0.72, size.height * 0.4))
        // con los controles a la vista (o con la letra encendida), la portada les hace sitio
        let sung = store.lyricsOnStage
        let aside: CGFloat = (stageShown || sung) && landscape ? -size.width * 0.21 : 0
        let lift: CGFloat = (stageShown || sung) && !landscape ? -size.height * 0.1 : 0
        return ZStack {
            // de borde a borde, también debajo de la isla y de la barra de inicio
            // el visual elegido en Ajustes; Ondas es la onda de siempre
            if store.visualStyle == .ondas {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    let (glow, depth) = visualColors(store.visualColor, glow: stageGlow ?? fg, depth: stageDepth ?? stageGlow ?? fg, seconds: timeline.date.timeIntervalSinceReferenceDate)
                    VStack {
                        Spacer()
                        StageWave(color: glow, depth: depth)
                            .frame(height: size.height * (landscape ? 0.3 : 0.22))
                    }
                }
                .ignoresSafeArea()
            } else {
                StageVisual(
                    style: store.visualStyle,
                    glow: stageGlow ?? fg,
                    depth: stageDepth ?? stageGlow ?? fg,
                    spectrum: spectrum,
                    cover: coverFrame,
                    shift: CGSize(width: aside, height: lift)
                )
                .task { await spectrum.listen(store.engine) }
            }
            // la portada justo en el centro de la pantalla; el título y el artista van debajo sin
            // moverla. Con el Anillo y el Vinilo va redonda, y con el Vinilo gira como el disco.
            TimelineView(.animation(paused: store.visualStyle != .pulso && store.visualStyle != .vinilo)) { timeline in
                Cover(url: state.coverLarge ?? state.track?.cover, size: cover, round: store.visualStyle.roundCover, fallback: state.track?.cover)
                    .rotationEffect(.degrees(store.visualStyle == .vinilo ? vinylTurn(timeline.date.timeIntervalSince(stageStart), calm: store.visualCalm) : 0))
                    .scaleEffect(pulseScale(store.visualStyle, spectrum, calm: store.visualCalm))
            }
            .frame(width: cover, height: cover)
            // dónde quedó la portada, para dibujar los visuales alrededor
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: CoverFrameKey.self, value: geometry.frame(in: .global))
                }
            }
            .shadow(color: .black.opacity(0.45), radius: 28, y: 14)
            .overlay(alignment: .top) {
                if let track = state.track {
                    VStack(spacing: 4) {
                        Text(track.title)
                            .font(landscape ? .title3.weight(.bold) : .title2.weight(.bold))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                        Text(track.artists)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(width: cover + 64)
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(y: cover + 18)
                }
            }
            .offset(x: aside, y: lift)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // la frase que suena, en el sitio de los controles (a la derecha de lado, abajo de
            // pie); cuando aparecen los controles se aparta
            if sung {
                Group {
                    if landscape {
                        HStack {
                            Spacer()
                            StageLine(big: true)
                                .frame(width: size.width * 0.42)
                                .padding(.trailing, 32)
                        }
                    } else {
                        VStack {
                            Spacer()
                            StageLine(big: false)
                                .padding(.horizontal, 24)
                                .padding(.bottom, size.height * 0.13)
                        }
                    }
                }
                .opacity(stageShown ? 0 : 1)
                .allowsHitTesting(false)
            }
            Group {
                if landscape {
                    // de lado: los controles a la derecha, a media altura, entrando desde el borde
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            seek(state)
                            controls(state)
                        }
                        .frame(width: size.width * 0.42)
                        .padding(.trailing, 32)
                        .offset(x: stageShown ? 0 : 48)
                    }
                } else {
                    VStack(spacing: 8) {
                        Spacer()
                        seek(state)
                        controls(state)
                    }
                    .frame(maxWidth: 620)
                    .padding(.horizontal, 24)
                    .padding(.bottom, size.height * 0.1)
                    .offset(y: stageShown ? 0 : 32)
                }
            }
            .opacity(stageShown ? 1 : 0)
            .allowsHitTesting(stageShown)
            VStack {
                HStack {
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.3)) { stage = false }
                    } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.title3.weight(.semibold))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Salir de pantalla completa")
                }
                Spacer()
            }
            .padding(12)
            .opacity(stageShown ? 1 : 0)
            .allowsHitTesting(stageShown)
        }
        .onPreferenceChange(CoverFrameKey.self) { coverFrame = $0 }
        .contentShape(Rectangle())
        .onTapGesture { stagePoke += 1 }
        .task(id: stagePoke) {
            withAnimation(.easeInOut(duration: 0.45)) { stageShown = true }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.9)) { stageShown = false }
            }
        }
        .task(id: state.track?.cover) {
            guard let url = state.track?.cover else { return }
            let image = await ImagePipeline.shared.image(url)
            let colors = image?.vividColors ?? []
            withAnimation(.easeInOut(duration: 0.8)) {
                stageGlow = colors.first
                stageDepth = colors.dropFirst().first
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private func menu(_ state: PlaybackState) -> some View {
        let slug = state.provider ?? store.selected
        return Menu {
            Button { adding = true } label: {
                Label("Agregar canciones a la cola", systemImage: "plus")
            }
            Button(role: .destructive) { store.engine.clearQueue() } label: {
                Label("Limpiar la cola", systemImage: "xmark.bin")
            }
            if let track = state.track {
                Button { playlist = PendingAdd(slug: slug, tracks: [track]) } label: {
                    Label("Agregar a una playlist…", systemImage: "text.badge.plus")
                }
                DownloadButton(track: track, slug: slug)
                DiscordButton(track: track, slug: slug)
                Button {
                    store.share(
                        .track,
                        id: track.id,
                        from: slug,
                        title: track.title,
                        subtitle: track.artists,
                        cover: track.cover
                    )
                } label: {
                    Label("Compartir…", systemImage: "square.and.arrow.up")
                }
                if !state.remote, let album = track.albumId {
                    Button {
                        dismiss()
                        open(.album(slug: slug, id: album))
                    } label: {
                        Label("Ir al álbum", systemImage: "square.stack")
                    }
                }
                if !state.remote, let artist = track.artistId {
                    Button {
                        dismiss()
                        open(.artist(slug: slug, id: artist))
                    } label: {
                        Label("Ir al artista", systemImage: "music.mic")
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .frame(width: 44, height: 44)
        }
    }

    @ViewBuilder
    private func center(_ state: PlaybackState) -> some View {
        switch panel {
        case nil:
            GeometryReader { geometry in
                Cover(
                    url: state.coverLarge ?? state.track?.cover,
                    size: min(geometry.size.width, geometry.size.height),
                    fallback: state.track?.cover
                )
                    .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .gesture(dismissDrag)
        case .lyrics:
            LyricsPanel()
        case .queue:
            QueuePanel { adding = true }
        case .session:
            SessionList(slug: state.provider)
                .scrollContentBackground(.hidden)
        }
    }

    private func info(_ track: TrackItem, slug: String) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.title3.weight(.bold))
                    .lineLimit(2)
                Text(track.artists)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            HeartButton(track: track, slug: slug)
        }
        .foregroundStyle(fg)
    }

    private func seek(_ state: PlaybackState) -> some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { scrub ?? Double(state.positionMs) },
                    set: { scrub = $0 }
                ),
                in: 0...max(1, Double(state.durationMs))
            ) { editing in
                if !editing, let target = scrub {
                    store.engine.seek(positionMs: UInt64(target))
                    scrub = nil
                }
            }
            HStack {
                Text(clock(UInt64(scrub ?? Double(state.positionMs))))
                Spacer()
                Text(clock(state.durationMs))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func controls(_ state: PlaybackState) -> some View {
        HStack(spacing: 0) {
            // del mismo ancho que el aleatorio, para que play quede en el centro
            Color.clear.frame(width: 44, height: 44)
            Spacer()
            Button { store.engine.previous() } label: {
                Image(systemName: "backward.fill").font(.system(size: 30))
            }
            Spacer()
            PlayButton(status: state.status, size: 44) { store.engine.toggle() }
            Spacer()
            Button { store.engine.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 30))
            }
            .disabled(state.index + 1 >= state.queueLength)
            Spacer()
            shuffleButton(state)
        }
        .buttonStyle(.plain)
        .foregroundStyle(fg)
    }

    /// Aleatorio por género: encendido, la siguiente es siempre una canción parecida a la que
    /// suena, elegida al azar (reemplaza lo que hubiera en la cola).
    @ViewBuilder
    private func shuffleButton(_ state: PlaybackState) -> some View {
        if state.remote {
            Color.clear.frame(width: 44, height: 44)
        } else {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                store.engine.setShuffle(on: !state.shuffle)
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "shuffle").font(.system(size: 20, weight: .semibold))
                    Circle().frame(width: 4, height: 4).opacity(state.shuffle ? 1 : 0)
                }
                .opacity(state.shuffle ? 1 : 0.5)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(state.shuffle ? "Apagar aleatorio por género" : "Aleatorio por género")
        }
    }

    /// En «solo controlar» se avisa de que la música suena en otro lado. El volumen va con los
    /// botones del iPhone.
    @ViewBuilder
    private func remoteNote(_ state: PlaybackState) -> some View {
        if state.remote {
            Label("Controlas la sesión: esto suena en los otros dispositivos.", systemImage: "slider.horizontal.3")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// Letra, cola y sesión. Volver a tocar el activo muestra la portada otra vez.
    private var toggles: some View {
        HStack(spacing: 6) {
            toggle(.lyrics, icon: "quote.bubble", label: "Letra")
            toggle(.queue, icon: "list.bullet", label: "Cola")
            toggle(.session, icon: "person.2.wave.2", label: "Sesión")
        }
        .padding(4)
        .background(fg.opacity(0.08), in: Capsule())
    }

    private func toggle(_ which: PlayerPanel, icon: String, label: String) -> some View {
        let on = panel == which
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { panel = on ? nil : which }
        } label: {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .frame(width: 52, height: 36)
                .background(on ? fg.opacity(0.2) : .clear, in: Capsule())
                .foregroundStyle(on ? fg : fg.opacity(0.6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// Deslizar hacia abajo cierra el reproductor.
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in drag = max(0, value.translation.height) }
            .onEnded { value in
                if value.translation.height > 140 || value.predictedEndTranslation.height > 320 {
                    dismiss()
                } else {
                    withAnimation(.spring()) { drag = 0 }
                }
            }
    }

    private func providerName(_ slug: String?) -> String? {
        store.providers.first(where: { $0.slug == slug })?.name
    }
}

/// El corazón: lleno si la canción está entre las guardadas. Con su propio estado por canción,
/// para que el cambio se vea al momento mientras el servicio lo confirma.
struct HeartButton: View {
    @EnvironmentObject private var store: Store
    let track: TrackItem
    let slug: String
    @State private var mine: Bool?

    var body: some View {
        // el motor avisa con un estado nuevo cuando termina de cargar las guardadas
        let saved = mine ?? store.engine.trackSaved(slug: slug, id: track.id)
        Button {
            let next = !saved
            mine = next
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            store.save(.track, id: track.id, from: slug, saved: next, quiet: true)
        } label: {
            Image(systemName: saved ? "heart.fill" : "heart")
                .font(.title2)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(saved ? "Quitar de tu biblioteca" : "Guardar en tu biblioteca")
        .id(track.id)
    }
}

/// Barras que siguen la música (32 bandas, de graves a agudos), leídas del motor unas 30 veces
/// por segundo mientras se ven. Al salir, el motor deja de analizar.
struct VisualizerView: View {
    @EnvironmentObject private var store: Store
    let color: Color
    @State private var bands: [Float] = []

    var body: some View {
        let style = store.visualizer
        Canvas { context, size in
            let count = bands.count
            guard count > 0 else { return }
            if style != .bars {
                // la onda: una línea suave que pasa por el nivel de cada banda
                let step = size.width / CGFloat(max(count - 1, 1))
                func y(_ level: Float) -> CGFloat {
                    size.height - CGFloat(min(max(level, 0), 1)) * size.height * 0.95 - 1
                }
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y(bands[0])))
                for index in 1..<count {
                    let x0 = CGFloat(index - 1) * step
                    let x1 = CGFloat(index) * step
                    let mid = (x0 + x1) / 2
                    path.addCurve(
                        to: CGPoint(x: x1, y: y(bands[index])),
                        control1: CGPoint(x: mid, y: y(bands[index - 1])),
                        control2: CGPoint(x: mid, y: y(bands[index]))
                    )
                }
                context.stroke(path, with: .color(color.opacity(0.9)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                if style == .wave { return }
            }
            let faded: CGFloat = style == .both ? 0.45 : 1
            let gap: CGFloat = 3
            let width = max(1, (size.width - gap * CGFloat(count - 1)) / CGFloat(count))
            for (index, level) in bands.enumerated() {
                let value = CGFloat(min(max(level, 0), 1))
                let height = max(2, value * size.height)
                let rect = CGRect(
                    x: CGFloat(index) * (width + gap),
                    y: size.height - height,
                    width: width,
                    height: height
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: width / 2),
                    with: .color(color.opacity((0.35 + 0.5 * value) * faded))
                )
            }
        }
        .task {
            let engine = store.engine
            while !Task.isCancelled {
                bands = await Task.detached { engine.spectrum() }.value
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
            engine.spectrumStop()
        }
        .accessibilityHidden(true)
    }
}

/// Las ondas de la pantalla completa, como la del escritorio: colinas suaves y rellenas que
/// siguen la música, con un brillo difuso del color de la portada. Adelante van los graves y
/// medios; atrás, más alta, transparente y lenta, otra con los agudos y el segundo color de la
/// portada, para dar profundidad. Se mueven suavizadas, sin saltos.
struct StageWave: View {
    @EnvironmentObject private var store: Store
    let color: Color
    let depth: Color
    @State private var front: [Float] = []
    @State private var back: [Float] = []

    /// Cuántos puntos tiene cada onda.
    private static let points = 24

    var body: some View {
        let light = color.lighter(0.35)
        let far = depth.lighter(0.2)
        ZStack {
            // el brillo: las mismas ondas, desenfocadas
            Canvas { context, size in
                if let path = StageWave.hills(back, in: size, base: 0.12, reach: 0.85) {
                    context.fill(path, with: .linearGradient(
                        Gradient(colors: [far.opacity(0.4), depth.opacity(0.05)]),
                        startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                }
                if let path = StageWave.hills(front, in: size, base: 0.05, reach: 0.7) {
                    context.fill(path, with: .linearGradient(
                        Gradient(colors: [light.opacity(0.85), color.opacity(0.2)]),
                        startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                }
            }
            .blur(radius: 24)
            Canvas { context, size in
                if let path = StageWave.hills(back, in: size, base: 0.12, reach: 0.85) {
                    context.fill(path, with: .linearGradient(
                        Gradient(colors: [far.opacity(0.28), depth.opacity(0.03)]),
                        startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                    context.stroke(path, with: .color(far.opacity(0.45)), lineWidth: 1.5)
                }
                if let path = StageWave.hills(front, in: size, base: 0.05, reach: 0.7) {
                    context.fill(path, with: .linearGradient(
                        Gradient(colors: [light.opacity(0.55), color.opacity(0.08)]),
                        startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                    context.stroke(path, with: .color(light.opacity(0.9)), lineWidth: 2)
                }
            }
        }
        .task {
            let engine = store.engine
            while !Task.isCancelled {
                let bands = await Task.detached { engine.spectrum() }.value
                if bands.count >= 2 {
                    front = StageWave.ease(front, StageWave.section(bands, from: 0, to: 0.6, gain: 1), 0.3)
                    // los agudos suenan más bajo: se les da más fuerza para que se vean
                    back = StageWave.ease(back, StageWave.section(bands, from: 0.35, to: 1, gain: 1.8), 0.15)
                }
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
            engine.spectrumStop()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Un tramo del espectro (de `from` a `to`, de 0 a 1), repartido en `points` puntos.
    static func section(_ bands: [Float], from: Float, to: Float, gain: Float) -> [Float] {
        let last = Float(bands.count - 1)
        return (0..<points).map { point in
            let at = (from + (to - from) * Float(point) / Float(points - 1)) * last
            let low = min(max(Int(at), 0), bands.count - 1)
            let high = min(low + 1, bands.count - 1)
            let mix = at - Float(low)
            return min(max((bands[low] * (1 - mix) + bands[high] * mix) * gain, 0), 1)
        }
    }

    /// Acerca `now` a `target` un poco (`amount`), para que la onda no salte.
    static func ease(_ now: [Float], _ target: [Float], _ amount: Float) -> [Float] {
        guard now.count == target.count else { return target }
        return zip(now, target).map { $0 + ($1 - $0) * amount }
    }

    /// El contorno de las colinas, cerrado por abajo para rellenarlo: `base` es la altura mínima
    /// y `reach` lo que sube con la música, como parte de la altura. `nil` sin música.
    static func hills(_ levels: [Float], in size: CGSize, base: CGFloat, reach: CGFloat) -> Path? {
        guard levels.count > 1 else { return nil }
        // un promedio con las vecinas redondea los picos, como en el escritorio
        let smooth: [CGFloat] = levels.indices.map { index in
            let left = levels[max(0, index - 1)]
            let right = levels[min(levels.count - 1, index + 1)]
            return CGFloat((left + 2 * levels[index] + right) / 4)
        }
        let step = size.width / CGFloat(smooth.count - 1)
        func y(_ level: CGFloat) -> CGFloat {
            let shaped = pow(min(max(level, 0), 1), 0.75)
            return size.height - (base + reach * shaped) * size.height
        }
        var path = Path()
        path.move(to: CGPoint(x: 0, y: size.height))
        path.addLine(to: CGPoint(x: 0, y: y(smooth[0])))
        for index in 1..<smooth.count {
            let x0 = CGFloat(index - 1) * step
            let x1 = CGFloat(index) * step
            let mid = (x0 + x1) / 2
            path.addCurve(
                to: CGPoint(x: x1, y: y(smooth[index])),
                control1: CGPoint(x: mid, y: y(smooth[index - 1])),
                control2: CGPoint(x: mid, y: y(smooth[index]))
            )
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        return path
    }
}

private extension Color {
    /// El mismo color, mezclado con blanco en la proporción `amount` (0 a 1).
    func lighter(_ amount: CGFloat) -> Color {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return Color(
            red: red + (1 - red) * amount,
            green: green + (1 - green) * amount,
            blue: blue + (1 - blue) * amount,
            opacity: alpha
        )
    }
}

/// La portada, muy desenfocada y con un velo, de fondo. Avisa si es clara, para poner encima
/// texto oscuro.
struct Backdrop: View {
    @EnvironmentObject private var store: Store
    let url: String?
    @Binding var light: Bool
    @State private var image: UIImage?
    @State private var colors: [Color] = []

    var body: some View {
        ZStack {
            Color(white: 0.08)
            if let image {
                Color.clear.overlay {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 80)
                        .scaleEffect(1.5)
                }
                .clipped()
                .transition(.opacity)
            }
            LinearGradient(
                colors: light
                    ? [.white.opacity(0.2), .white.opacity(0.4)]
                    : [.black.opacity(0.3), .black.opacity(0.6)],
                startPoint: .top,
                endPoint: .bottom
            )
            if store.ambient, !colors.isEmpty {
                AmbientField(colors: colors)
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.4), value: image)
        .task(id: url) {
            image = url.flatMap { ImagePipeline.shared.cached($0) }
            if image == nil, let url {
                image = await ImagePipeline.shared.image(url)
            }
            light = (image?.averageLuminance ?? 0) > 0.6
            colors = image?.vividColors ?? []
        }
    }
}

/// «Fondo ambiental»: manchas grandes con los colores de la portada que se desplazan despacio,
/// como en la app de escritorio.
struct AmbientField: View {
    let colors: [Color]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let phase: Double = timeline.date.timeIntervalSinceReferenceDate * (2 * Double.pi / 24)
            Canvas { context, size in
                let reach = max(size.width, size.height)
                for (index, color) in colors.enumerated() {
                    let offset = Double(index)
                    let angle: Double = phase + offset * 1.7
                    let across: Double = 0.5 + 0.35 * cos(angle + offset)
                    let down: Double = 0.45 + 0.3 * sin(angle * 0.8 + offset * 2)
                    let center = CGPoint(x: size.width * CGFloat(across), y: size.height * CGFloat(down))
                    let grow: Double = 0.55 + 0.1 * sin(angle * 1.3)
                    let radius: CGFloat = reach * CGFloat(grow)
                    let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                    context.fill(
                        Path(ellipseIn: rect),
                        with: .radialGradient(
                            Gradient(colors: [color.opacity(0.35), .clear]),
                            center: center,
                            startRadius: 0,
                            endRadius: radius
                        )
                    )
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension UIImage {
    /// Hasta cuatro colores vivos de la imagen, el más saturado primero, para el fondo ambiental y
    /// los colores de la portada.
    var vividColors: [Color] {
        guard let source = cgImage else { return [] }
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return [] }
        var found: [(hue: CGFloat, score: CGFloat, color: UIColor)] = []
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let color = UIColor(
                red: CGFloat(pixels[index]) / 255,
                green: CGFloat(pixels[index + 1]) / 255,
                blue: CGFloat(pixels[index + 2]) / 255,
                alpha: 1
            )
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
            color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
            found.append((hue, saturation * (0.4 + brightness), color))
        }
        found.sort { $0.score > $1.score }
        var picked: [(hue: CGFloat, color: UIColor)] = []
        for candidate in found where picked.count < 4 {
            let distinct = picked.allSatisfy { abs($0.hue - candidate.hue) > 0.08 }
            if distinct { picked.append((candidate.hue, candidate.color)) }
        }
        return picked.map { Color(uiColor: $0.color) }
    }

    /// El brillo medio de la imagen (0 negro, 1 blanco).
    var averageLuminance: CGFloat? {
        guard let source = cgImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn: Bool = pixel.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(source, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return nil }
        let red = CGFloat(pixel[0]) / 255
        let green = CGFloat(pixel[1]) / 255
        let blue = CGFloat(pixel[2]) / 255
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }
}

// MARK: - Cola

/// La cola: tocar salta a la canción, deslizar a la izquierda la quita, y con «Ordenar» se
/// arrastran por el asa (≡) a otro puesto o se quitan con el botón rojo.
struct QueuePanel: View {
    @EnvironmentObject private var store: Store
    let onAdd: () -> Void
    @State private var editing: EditMode = .inactive

    var body: some View {
        let queue = store.engine.queue()
        let current = Int(store.state.index)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Cola").font(.title3.bold())
                Spacer()
                Button(action: onAdd) { Label("Agregar", systemImage: "plus") }
                Button {
                    withAnimation { editing = editing.isEditing ? .inactive : .active }
                } label: {
                    Label(editing.isEditing ? "Listo" : "Ordenar", systemImage: editing.isEditing ? "checkmark" : "arrow.up.arrow.down")
                }
                Button { store.engine.clearQueue() } label: { Label("Limpiar", systemImage: "xmark.bin") }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .font(.subheadline)
            if queue.count <= current + 1 {
                Text("No hay nada después de esta canción. Toca «Agregar» para sumar más.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(queue.enumerated()), id: \.offset) { index, track in
                        Button {
                            store.engine.jump(index: UInt32(index))
                        } label: {
                            TrackRow(track: track, current: index == current)
                        }
                        .buttonStyle(.plain)
                        .opacity(index < current ? 0.5 : 1)
                        .deleteDisabled(index == current)
                        .listRowBackground(index == current ? Color.primary.opacity(0.12) : Color.clear)
                    }
                    .onDelete { offsets in
                        for index in offsets.sorted(by: >) {
                            store.engine.removeFromQueue(index: UInt32(index))
                        }
                    }
                    .onMove { source, destination in
                        guard let from = source.first else { return }
                        // `destination` cuenta el hueco antes de quitar la que se mueve
                        let to = destination > from ? destination - 1 : destination
                        store.engine.moveInQueue(from: UInt32(from), to: UInt32(to))
                    }
                }
                .listStyle(.plain)
                .environment(\.editMode, $editing)
                .scrollContentBackground(.hidden)
                .onAppear { proxy.scrollTo(max(0, current - 1), anchor: .top) }
            }
        }
    }
}

/// Buscar canciones y sumarlas a la cola sin salir del reproductor.
struct AddSongsView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    let slug: String
    @State private var query = ""
    @State private var results: [TrackItem] = []
    @State private var searching = false
    @State private var added: Set<String> = []

    var body: some View {
        NavigationStack {
            List(results, id: \.id) { track in
                HStack(spacing: 10) {
                    Cover(url: track.cover, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title).lineLimit(1)
                        Text(track.artists).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if added.contains(track.id) {
                        Image(systemName: "checkmark").foregroundStyle(.secondary)
                    } else {
                        Button {
                            store.enqueue([track], next: true, from: slug)
                            added.insert(track.id)
                        } label: {
                            Image(systemName: "text.line.first.and.arrowtriangle.forward").font(.title3)
                        }
                        .accessibilityLabel("Reproducir a continuación")
                        Button {
                            store.enqueue([track], next: false, from: slug)
                            added.insert(track.id)
                        } label: {
                            Image(systemName: "plus.circle").font(.title3)
                        }
                        .accessibilityLabel("Agregar al final")
                    }
                }
                .buttonStyle(.borderless)
            }
            .listStyle(.plain)
            .overlay {
                if searching { ProgressView() }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Buscar canciones")
            .onSubmit(of: .search, run)
            .navigationTitle("Agregar a la cola")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { dismiss() }
                }
            }
        }
    }

    private func run() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        searching = true
        Task {
            results = await store.search(text, in: slug)
            searching = false
        }
    }
}

/// Dónde está la portada de la pantalla completa, en coordenadas de la pantalla.
private struct CoverFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isEmpty { value = next }
    }
}

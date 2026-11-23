import Foundation
import Network
import SwiftUI

/// Un aviso del motor que espera respuesta del usuario durante el inicio de sesión.
struct PendingPrompt: Identifiable {
    let id = UUID()
    let slug: String
    let prompt: Prompt
}

/// Recibe los avisos del motor, que llegan desde hilos de Rust, y los pasa al hilo principal.
final class Bridge: EngineListener, @unchecked Sendable {
    weak var store: Store?

    func onPrompt(slug: String, prompt: Prompt) {
        Task { @MainActor [weak self] in self?.store?.prompted(slug: slug, prompt: prompt) }
    }

    func onState(state: PlaybackState) {
        Task { @MainActor [weak self] in self?.store?.apply(state) }
    }

    func onProblem(message: String) {
        Task { @MainActor [weak self] in
            self?.store?.problem = message
            self?.store?.sessionBusy = false
        }
    }

    func onSession(session: SessionInfo?) {
        Task { @MainActor [weak self] in self?.store?.sessionChanged(session) }
    }
}

/// El estado de la app: cuentas, reproducción y avisos. Todas las llamadas que bloquean al motor
/// van fuera del hilo principal.
@MainActor
final class Store: ObservableObject {
    let engine: Engine
    private let bridge: Bridge
    private let nowPlaying = NowPlaying()
    private let minter = PoTokenMinter()

    @Published var providers: [ProviderInfo] = []
    @Published var state: PlaybackState
    @Published var prompt: PendingPrompt?
    @Published var problem: String?
    @Published var signingIn: String?
    /// La Sonora Session en la que está la app.
    @Published var session: SessionInfo?
    /// Se está creando o uniendo a una sesión.
    @Published var sessionBusy = false
    @Published var audio: AudioSettings
    /// Canciones que esperan elegir a qué playlist van.
    @Published var addingToPlaylist: PendingAdd?
    /// Elemento abierto en la hoja de compartir.
    @Published var sharing: ShareTarget?
    /// Sube cada vez que cambian las playlists, para recargar la biblioteca.
    @Published var libraryRevision = 0
    /// El proveedor en el que se busca.
    @Published var selected: String = UserDefaults.standard.string(forKey: "selected") ?? "youtube" {
        didSet { if selected != "local" { UserDefaults.standard.set(selected, forKey: "selected") } }
    }
    /// Si la persona ya tocó una pestaña de servicio desde que abrió la app.
    var picked = false
    /// El servicio con el que abre la app: el último elegido que no sea la música del teléfono.
    private var favorite: String { UserDefaults.standard.string(forKey: "selected") ?? "youtube" }
    /// Mientras se recuperan las sesiones guardadas al abrir la app.
    @Published var restoring = false

    init() {
        let bridge = Bridge()
        self.bridge = bridge
        engine = Engine(listener: bridge)
        state = engine.state()
        audio = engine.audioSettings()
        bridge.store = self
        if let saved = Self.savedAudio() {
            engine.setAudioSettings(settings: saved)
            audio = saved
        }
        nowPlaying.attach(engine: engine)
        minter.start()
        refresh()
        restoreStored()
        if UserDefaults.standard.bool(forKey: "local.on") { openLocal(quiet: true) }
        network.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            DispatchQueue.main.async { self?.online = connected }
        }
        network.start(queue: DispatchQueue(label: "tk-music.network"))
    }

    var signedIn: [ProviderInfo] { providers.filter(\.signedIn) }

    func refresh() {
        providers = engine.providers()
        // al abrir, la música del teléfono suele estar lista antes que YouTube Music; cuando llega
        // el servicio de siempre vuelve a ser el elegido, salvo que la persona haya tocado otro
        let preferred = favorite
        if !picked, preferred != selected, signedIn.contains(where: { $0.slug == preferred }) {
            setSelected(preferred)
        } else if !signedIn.contains(where: { $0.slug == selected }),
                  let first = signedIn.first(where: { $0.slug != "local" }) ?? signedIn.first {
            setSelected(first.slug)
        }
    }

    /// Cambia el servicio elegido sin contarlo como elección de la persona ni recordarlo.
    private func setSelected(_ slug: String) {
        let remembered = UserDefaults.standard.string(forKey: "selected")
        selected = slug
        if let remembered { UserDefaults.standard.set(remembered, forKey: "selected") }
    }

    func account(_ slug: String) -> Account? { engine.account(slug: slug) }

    // MARK: Personalización

    @Published var palette = Palette(rawValue: UserDefaults.standard.string(forKey: "look.palette") ?? "") ?? .system {
        didSet { UserDefaults.standard.set(palette.rawValue, forKey: "look.palette") }
    }
    @Published var appearance = Appearance(rawValue: UserDefaults.standard.string(forKey: "look.mode") ?? "") ?? .system {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "look.mode") }
    }
    /// El nombre del saludo de Inicio («Hola, …»).
    /// Si el teléfono tiene internet ahora mismo.
    @Published private(set) var online = true
    /// El modo sin conexión elegido a mano en Ajustes, aunque haya internet (para ahorrar datos).
    @Published var offlineMode = UserDefaults.standard.bool(forKey: "offline.mode") {
        didSet { UserDefaults.standard.set(offlineMode, forKey: "offline.mode") }
    }
    /// Si la app se muestra sin conexión: sin internet, o con el modo puesto a mano.
    var offline: Bool { !online || offlineMode }
    /// Avisa cuando el teléfono gana o pierde internet.
    private let network = NWPathMonitor()

    /// «Colores de la portada»: el color de lo que suena tiñe toda la app.
    @Published var adaptive = UserDefaults.standard.bool(forKey: "look.adaptive") {
        didSet { UserDefaults.standard.set(adaptive, forKey: "look.adaptive") }
    }
    /// El color más vivo de la portada de lo que suena, para el tema adaptativo.
    @Published var coverAccent: Color?
    /// «Fondo ambiental»: los colores de la portada se mueven despacio detrás del reproductor.
    @Published var ambient = UserDefaults.standard.object(forKey: "look.ambient") as? Bool ?? true {
        didSet { UserDefaults.standard.set(ambient, forKey: "look.ambient") }
    }
    /// Cómo se dibuja el visualizador.
    @Published var visualizer = VisualizerStyle(rawValue: UserDefaults.standard.string(forKey: "look.visualizer") ?? "") ?? .bars {
        didSet { UserDefaults.standard.set(visualizer.rawValue, forKey: "look.visualizer") }
    }
    /// El color de acento de la app: el de la portada con «Colores de la portada», si no el del tema.
    var accent: Color { adaptive ? (coverAccent ?? palette.color) : palette.color }

    /// Saca el color más vivo de la portada de lo que suena, para «Colores de la portada».
    func refreshAccent() async {
        guard adaptive, let url = state.track?.cover else { return }
        let image = await ImagePipeline.shared.image(url)
        let color = image?.vividColors.first
        withAnimation(.easeInOut(duration: 0.8)) { coverAccent = color }
    }

    /// Si se muestra la pronunciación de las letras en otros sistemas de escritura.
    @Published var showRomanized = UserDefaults.standard.object(forKey: "lyrics.romanized") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showRomanized, forKey: "lyrics.romanized") }
    }
    /// Cómo se anima la letra sincronizada.
    @Published var lyricStyle = LyricStyle(rawValue: UserDefaults.standard.string(forKey: "lyrics.style") ?? "") ?? .enfoque {
        didSet { UserDefaults.standard.set(lyricStyle.rawValue, forKey: "lyrics.style") }
    }
    /// Qué va detrás de la letra.
    @Published var lyricBackdrop = LyricBackdrop(rawValue: UserDefaults.standard.string(forKey: "lyrics.backdrop") ?? "") ?? .portada {
        didSet { UserDefaults.standard.set(lyricBackdrop.rawValue, forKey: "lyrics.backdrop") }
    }
    /// El tamaño de la letra: 0,82 chica, 1 normal, 1,2 grande.
    @Published var lyricSize = UserDefaults.standard.object(forKey: "lyrics.size") as? Double ?? 1 {
        didSet { UserDefaults.standard.set(lyricSize, forKey: "lyrics.size") }
    }
    /// La letra a la izquierda en vez de al centro.
    @Published var lyricStart = UserDefaults.standard.bool(forKey: "lyrics.start") {
        didSet { UserDefaults.standard.set(lyricStart, forKey: "lyrics.start") }
    }
    /// Resaltar en blanco en vez del color de la portada.
    @Published var lyricWhite = UserDefaults.standard.bool(forKey: "lyrics.white") {
        didSet { UserDefaults.standard.set(lyricWhite, forKey: "lyrics.white") }
    }
    /// La frase que suena encima de la pantalla completa.
    @Published var lyricsOnStage = UserDefaults.standard.object(forKey: "lyrics.stage") as? Bool ?? false {
        didSet { UserDefaults.standard.set(lyricsOnStage, forKey: "lyrics.stage") }
    }
    /// La frase que suena en la barra de abajo, en vez del artista.
    @Published var lyricsInBar = UserDefaults.standard.object(forKey: "lyrics.bar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(lyricsInBar, forKey: "lyrics.bar") }
    }
    /// El visual de la pantalla completa.
    @Published var visualStyle = VisualStyle(rawValue: UserDefaults.standard.string(forKey: "visual.style") ?? "") ?? .ondas {
        didSet { UserDefaults.standard.set(visualStyle.rawValue, forKey: "visual.style") }
    }
    /// Los colores de los visuales: los de la portada o un arcoíris.
    @Published var visualColor = VisualColor(rawValue: UserDefaults.standard.string(forKey: "visual.color") ?? "") ?? .portada {
        didSet { UserDefaults.standard.set(visualColor.rawValue, forKey: "visual.color") }
    }
    /// Los visuales más lentos y sin saltos fuertes.
    @Published var visualCalm = UserDefaults.standard.bool(forKey: "visual.calm") {
        didSet { UserDefaults.standard.set(visualCalm, forKey: "visual.calm") }
    }
    /// La frase que suena en la isla dinámica y la pantalla bloqueada (apagado hasta que se active).
    @Published var liveLyrics = UserDefaults.standard.bool(forKey: "lyrics.live") {
        didSet { UserDefaults.standard.set(liveLyrics, forKey: "lyrics.live") }
    }
    /// El webhook del canal #tk-music del bot de Discord, o "" si no se configuró.
    @Published var discordWebhook = UserDefaults.standard.string(forKey: "discord.webhook") ?? "" {
        didSet { UserDefaults.standard.set(discordWebhook, forKey: "discord.webhook") }
    }
    @Published var userName = UserDefaults.standard.string(forKey: "look.name") ?? "" {
        didSet { UserDefaults.standard.set(userName, forKey: "look.name") }
    }

    // MARK: Búsquedas recientes

    @Published private(set) var recentSearches: [String] =
        UserDefaults.standard.stringArray(forKey: "search.recent") ?? []

    /// Guarda una búsqueda (la más nueva primero, sin repetir, hasta 12).
    func rememberSearch(_ text: String) {
        recentSearches = Array(([text] + recentSearches.filter { $0.caseInsensitiveCompare(text) != .orderedSame }).prefix(12))
        UserDefaults.standard.set(recentSearches, forKey: "search.recent")
    }

    // MARK: Canciones del iPhone

    @Published var localBusy = false

    /// La carpeta de Sonora en Archivos («En mi iPhone › Sonora»): ahí va la música.
    static var musicFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Busca (o vuelve a buscar) las canciones de la carpeta de Sonora.
    func openLocal(quiet: Bool = false) {
        localBusy = true
        let engine = self.engine
        let folder = Self.musicFolder.path
        Task {
            let result = await Task.detached { Result(catching: { try engine.openLocal(folders: [folder]) }) }.value
            switch result {
            case .success:
                UserDefaults.standard.set(true, forKey: "local.on")
            case .failure(let error):
                if !quiet { problem = describe(error) }
            }
            localBusy = false
            libraryRevision += 1
            refresh()
        }
    }

    func closeLocal() {
        UserDefaults.standard.set(false, forKey: "local.on")
        signOut("local")
    }

    /// Copia a la carpeta de Sonora los archivos elegidos en Archivos y vuelve a buscar.
    func importSongs(_ urls: [URL]) {
        let folder = Self.musicFolder
        var failed = 0
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let target = folder.appendingPathComponent(url.lastPathComponent)
            do {
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.copyItem(at: url, to: target)
            } catch {
                failed += 1
            }
        }
        if failed > 0 { problem = "No pude copiar \(failed) de los archivos." }
        openLocal()
    }

    /// Recupera las sesiones guardadas al abrir la app.
    private func restoreStored() {
        let engine = self.engine
        let stored = providers.filter { $0.stored && !$0.signedIn }
        var pending = stored.count
        restoring = pending > 0
        for provider in stored {
            let slug = provider.slug
            let name = provider.name
            Task.detached { [weak self] in
                let result = Result(catching: { try engine.restore(slug: slug) })
                await MainActor.run {
                    guard let self else { return }
                    // sin internet no se avisa: lo descargado suena igual
                    if case .failure(let error) = result, self.online {
                        self.problem = "\(name): \(describe(error))"
                    }
                    self.refresh()
                    pending -= 1
                    if pending == 0 { self.restoring = false }
                }
            }
        }
    }

    func signIn(_ provider: ProviderInfo, method: SignInMethod) {
        signingIn = provider.slug
        let engine = self.engine
        let slug = provider.slug
        Task.detached { [weak self] in
            let result = Result(catching: { try engine.signIn(slug: slug, method: method) })
            await MainActor.run {
                guard let self else { return }
                self.signingIn = nil
                self.prompt = nil
                if case .failure(let error) = result {
                    self.problem = describe(error)
                } else {
                    self.selected = slug
                }
                self.refresh()
            }
        }
    }

    func cancelSignIn() {
        engine.cancelSignIn()
        prompt = nil
    }

    /// Si el usuario cerró la hoja del inicio de sesión a mano, se abandona.
    func promptDismissed() {
        if prompt == nil, signingIn != nil {
            engine.cancelSignIn()
        }
    }

    func answer(_ text: String) {
        engine.sendInput(text: text)
    }

    func signOut(_ slug: String) {
        engine.signOut(slug: slug)
        refresh()
    }

    func search(_ query: String, in slug: String) async -> [TrackItem] {
        let engine = self.engine
        let result = await Task.detached {
            Result(catching: { try engine.search(slug: slug, query: query) })
        }.value
        switch result {
        case .success(let tracks):
            return tracks
        case .failure(let error):
            problem = describe(error)
            return []
        }
    }

    func play(_ tracks: [TrackItem], at index: Int, from slug: String) {
        let engine = self.engine
        Task.detached { [weak self] in
            let result = Result(catching: {
                try engine.playQueue(slug: slug, tracks: tracks, index: UInt32(index))
            })
            if case .failure(let error) = result {
                await MainActor.run { self?.problem = describe(error) }
            }
        }
    }

    /// Corre algo que bloquea al motor fuera del hilo principal.
    func run<T>(_ work: @escaping (Engine) throws -> T) async -> Result<T, Error> {
        let engine = self.engine
        return await Task.detached { Result(catching: { try work(engine) }) }.value
    }

    func enqueue(_ tracks: [TrackItem], next: Bool, from slug: String) {
        Task {
            if case .failure(let error) = await run({ try $0.enqueue(slug: slug, tracks: tracks, next: next) }) {
                problem = describe(error)
            }
        }
    }

    /// Toca una canción y detrás pone las parecidas en género y ritmo (la radio de esa canción),
    /// en vez de la lista donde estaba. Suena enseguida; las parecidas llegan un momento después.
    func playSimilar(_ track: TrackItem, from slug: String) {
        Task {
            if case .failure(let error) = await run({ try $0.playQueue(slug: slug, tracks: [track], index: 0) }) {
                problem = describe(error)
                return
            }
            guard case .success(let found) = await run({ try $0.radio(slug: slug, trackId: track.id) }) else { return }
            let rest = found.filter { $0.id != track.id }
            // si mientras tanto se puso otra cosa, no se toca esa cola
            guard !rest.isEmpty, state.track?.id == track.id else { return }
            _ = await run { try $0.enqueue(slug: slug, tracks: rest, next: false) }
        }
    }

    func startRadio(_ track: TrackItem, from slug: String) {
        Task {
            switch await run({ try $0.radio(slug: slug, trackId: track.id) }) {
            case .success(let tracks):
                var queue = tracks
                if !queue.contains(where: { $0.id == track.id }) { queue.insert(track, at: 0) }
                play(queue, at: 0, from: slug)
            case .failure(let error):
                problem = describe(error)
            }
        }
    }

    func save(_ kind: SavedKind, id: String, from slug: String, saved: Bool = true, quiet: Bool = false) {
        Task {
            switch await run({ try $0.setSaved(slug: slug, kind: kind, id: id, saved: saved) }) {
            case .success:
                if !quiet { problem = saved ? "Guardado en tu biblioteca." : "Quitado de tu biblioteca." }
            case .failure(let error):
                problem = describe(error)
            }
        }
    }

    // MARK: Descargas para escuchar sin internet

    /// Las canciones que se están descargando ahora, por id.
    @Published var downloading: Set<String> = []
    /// Sube cada vez que cambia lo descargado, para que las pantallas vuelvan a preguntar.
    @Published var downloadRevision = 0

    /// Solo las canciones de YouTube Music se pueden descargar y escuchar sin conexión.
    func canDownload(_ slug: String) -> Bool { slug == "youtube" }

    func isDownloaded(_ track: TrackItem, from slug: String) -> Bool {
        canDownload(slug) && engine.isDownloaded(slug: slug, id: track.id)
    }

    /// Descarga las canciones una tras otra para escucharlas sin internet.
    func download(_ tracks: [TrackItem], from slug: String) {
        let pending = tracks.filter { !downloading.contains($0.id) }
        guard !pending.isEmpty else { return }
        pending.forEach { downloading.insert($0.id) }
        if pending.count > 1 { problem = "Guardando \(pending.count) canciones para sin conexión…" }
        Task {
            var done = 0
            var failure: Error?
            for track in pending {
                switch await run({ try $0.downloadTrack(slug: slug, track: track) }) {
                case .success: done += 1
                case .failure(let error): failure = error
                }
                downloading.remove(track.id)
                downloadRevision += 1
            }
            if let failure, done == 0 {
                problem = "No se pudo guardar para sin conexión: \(describe(failure))"
            } else if failure != nil {
                problem = "Se guardaron \(done) de \(pending.count) canciones."
            } else {
                problem = pending.count == 1 ? "Guardada: ya suena sin conexión." : "Listo: \(done) canciones guardadas para sin conexión."
            }
        }
    }

    func removeDownload(_ track: TrackItem, from slug: String) {
        Task {
            _ = await run { $0.removeDownload(slug: slug, id: track.id) }
            downloadRevision += 1
            problem = "Quitada de sin conexión."
        }
    }

    // MARK: Ajustes de audio

    private static let audioKey = "audio-settings"

    private static func savedAudio() -> AudioSettings? {
        guard let saved = UserDefaults.standard.dictionary(forKey: audioKey) else { return nil }
        let quality: AudioQuality
        switch saved["quality"] as? String {
        case "low": quality = .low
        case "normal": quality = .normal
        case "lossless": quality = .lossless
        case "hires": quality = .hiRes
        default: quality = .high
        }
        return AudioSettings(
            quality: quality,
            normalisation: saved["normalisation"] as? Bool ?? true,
            gapless: saved["gapless"] as? Bool ?? true,
            equalizer: saved["equalizer"] as? Bool ?? false,
            bands: saved["bands"] as? [Double] ?? Array(repeating: 0, count: 10)
        )
    }

    func applyAudio(_ settings: AudioSettings) {
        audio = settings
        let quality: String
        switch settings.quality {
        case .low: quality = "low"
        case .normal: quality = "normal"
        case .high: quality = "high"
        case .lossless: quality = "lossless"
        case .hiRes: quality = "hires"
        }
        UserDefaults.standard.set([
            "quality": quality,
            "normalisation": settings.normalisation,
            "gapless": settings.gapless,
            "equalizer": settings.equalizer,
            "bands": settings.bands,
        ] as [String: Any], forKey: Self.audioKey)
        let engine = self.engine
        Task.detached { engine.setAudioSettings(settings: settings) }
    }

    // MARK: Playlists

    func createPlaylist(_ name: String, in slug: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        Task {
            switch await run({ try $0.createPlaylist(slug: slug, name: name) }) {
            case .success: libraryRevision += 1
            case .failure(let error): problem = describe(error)
            }
        }
    }

    func renamePlaylist(_ id: String, to name: String, in slug: String) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return false }
        switch await run({ try $0.renamePlaylist(slug: slug, id: id, name: name) }) {
        case .success:
            libraryRevision += 1
            return true
        case .failure(let error):
            problem = describe(error)
            return false
        }
    }

    func deletePlaylist(_ id: String, in slug: String) async -> Bool {
        switch await run({ try $0.deletePlaylist(slug: slug, id: id) }) {
        case .success:
            libraryRevision += 1
            return true
        case .failure(let error):
            problem = describe(error)
            return false
        }
    }

    func addToPlaylist(_ playlist: PlaylistItem, adding: PendingAdd) {
        addingToPlaylist = nil
        let ids = adding.tracks.map(\.id)
        let slug = adding.slug
        Task {
            switch await run({ try $0.addToPlaylist(slug: slug, playlist: playlist.id, tracks: ids) }) {
            case .success:
                problem = "Agregada a «\(playlist.title)»."
                libraryRevision += 1
            case .failure(let error):
                problem = describe(error)
            }
        }
    }

    func removeFromPlaylist(_ playlist: String, track: String, in slug: String) async -> Bool {
        switch await run({ try $0.removeFromPlaylist(slug: slug, playlist: playlist, track: track) }) {
        case .success: return true
        case .failure(let error):
            problem = describe(error)
            return false
        }
    }

    func createPlaylistAndAdd(_ name: String, adding: PendingAdd) {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        addingToPlaylist = nil
        let ids = adding.tracks.map(\.id)
        let slug = adding.slug
        Task {
            switch await run({ engine in
                let id = try engine.createPlaylist(slug: slug, name: clean)
                try engine.addToPlaylist(slug: slug, playlist: id, tracks: ids)
            }) {
            case .success:
                problem = "Creada «\(clean)» y agregada."
                libraryRevision += 1
            case .failure(let error):
                problem = describe(error)
            }
        }
    }

    func setPlaylistPublic(_ id: String, public isPublic: Bool, in slug: String) async -> Bool {
        switch await run({ try $0.setPlaylistPublic(slug: slug, id: id, isPublic: isPublic) }) {
        case .success:
            libraryRevision += 1
            return true
        case .failure(let error):
            problem = describe(error)
            return false
        }
    }

    func setPlaylistCover(_ id: String, image: Data?, in slug: String) async -> Bool {
        switch await run({ try $0.setPlaylistCover(slug: slug, id: id, image: image) }) {
        case .success:
            libraryRevision += 1
            return true
        case .failure(let error):
            problem = describe(error)
            return false
        }
    }

    func canSetPlaylistCover(in slug: String) -> Bool {
        engine.canSetPlaylistCover(slug: slug)
    }

    // MARK: Compartir

    func share(
        _ kind: SavedKind,
        id: String,
        from slug: String,
        title: String,
        subtitle: String,
        cover: String?
    ) {
        Task {
            let url = await Task.detached(priority: .userInitiated) { [engine] in
                engine.shareUrl(slug: slug, kind: kind, id: id)
            }.value
            guard let url, !url.isEmpty else {
                problem = "Este elemento no tiene un enlace para compartir."
                return
            }
            sharing = ShareTarget(
                title: title,
                subtitle: subtitle,
                cover: cover,
                url: url,
                round: kind == .artist
            )
        }
    }

    // MARK: Scrobbling

    /// Vincula un servicio de scrobbling; Last.fm y Libre.fm abren la aprobación en Safari.
    func linkScrobble(_ id: String, key: String, secret: String, token: String, server: String) async -> Bool {
        let result = await run({
            try $0.scrobbleConnect(id: id, key: key, secret: secret, token: token, server: server)
        })
        prompt = nil
        switch result {
        case .success: return true
        case .failure(let error):
            problem = describe(error)
            return false
        }
    }

    func startSession(from slug: String? = nil) {
        sessionBusy = true
        let slug = slug ?? selected
        Task {
            if case .failure(let error) = await run({ try $0.sessionStart(slug: slug) }) {
                problem = describe(error)
                sessionBusy = false
            }
        }
    }

    func joinSession(_ code: String, remote: Bool) {
        sessionBusy = true
        Task {
            if case .failure(let error) = await run({ try $0.sessionJoin(code: code, remote: remote) }) {
                problem = describe(error)
                sessionBusy = false
            }
        }
    }

    func sessionChanged(_ info: SessionInfo?) {
        session = info
        if info != nil { sessionBusy = false }
    }

    func prompted(slug: String, prompt: Prompt) {
        self.prompt = PendingPrompt(slug: slug, prompt: prompt)
    }

    /// Cuándo llegó el último estado, para adelantar la posición entre uno y otro.
    private(set) var stateAt = Date()

    /// La posición ahora: el motor la da cada medio segundo y entre medio se adelanta con el
    /// reloj, para que el karaoke encienda cada palabra a tiempo.
    func smoothPosition(at date: Date) -> UInt64 {
        guard state.status == .playing else { return state.positionMs }
        let extra = min(1500, max(0, date.timeIntervalSince(stateAt) * 1000))
        return min(max(state.durationMs, state.positionMs), state.positionMs + UInt64(extra))
    }

    func apply(_ state: PlaybackState) {
        stateAt = Date()
        self.state = state
        nowPlaying.update(state)
    }
}

/// Canciones que esperan elegir a qué playlist van.
struct PendingAdd: Identifiable {
    let id = UUID()
    let slug: String
    let tracks: [TrackItem]
}

/// Elemento que se muestra en la hoja de compartir.
struct ShareTarget: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let cover: String?
    let url: String
    let round: Bool
}

/// El mensaje de un error del motor, sin el nombre del tipo delante.
func describe(_ error: Error) -> String {
    if error is MobileError {
        let payload = Mirror(reflecting: error).children.first?.value
        if let message = payload as? String {
            return message
        }
        if let payload, let message = Mirror(reflecting: payload).children.first?.value as? String {
            return message
        }
    }
    return String(describing: error)
}

/// `1:05` para 65 000 ms.
func clock(_ milliseconds: UInt64) -> String {
    let seconds = Int(milliseconds / 1000)
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}

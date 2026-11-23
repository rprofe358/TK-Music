package org.sonora.mobile

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import uniffi.sonora_mobile.AudioQuality
import uniffi.sonora_mobile.AudioSettings
import uniffi.sonora_mobile.Engine
import uniffi.sonora_mobile.EngineListener
import uniffi.sonora_mobile.PlaybackState
import uniffi.sonora_mobile.PlaylistItem
import uniffi.sonora_mobile.Prompt
import uniffi.sonora_mobile.ProviderInfo
import uniffi.sonora_mobile.SavedKind
import uniffi.sonora_mobile.SessionInfo
import uniffi.sonora_mobile.SignInMethod
import uniffi.sonora_mobile.TrackItem
import androidx.compose.runtime.mutableStateListOf

/** Un aviso del motor que espera respuesta durante el inicio de sesión. */
data class PendingPrompt(val slug: String, val prompt: Prompt, val id: Long = System.nanoTime())

/** Canciones que esperan elegir a qué playlist van. */
data class PendingAdd(val slug: String, val tracks: List<TrackItem>)

data class ShareTarget(
    val title: String,
    val subtitle: String,
    val cover: String?,
    val url: String,
    val round: Boolean = false,
    val slug: String = "",
    val track: TrackItem? = null,
)

/**
 * El estado de la app: cuentas, reproducción y avisos. Los avisos del motor llegan desde hilos
 * de Rust y se pasan al hilo principal; todo lo que bloquea al motor va en Dispatchers.IO.
 */
object Store : EngineListener {
    private val main = Handler(Looper.getMainLooper())
    val scope = MainScope()
    lateinit var engine: Engine
        private set
    lateinit var app: Context
        private set
    val minter = PoTokenMinter()

    var providers by mutableStateOf(listOf<ProviderInfo>())
    var state by mutableStateOf<PlaybackState?>(null)
    var prompt by mutableStateOf<PendingPrompt?>(null)
    var problem by mutableStateOf<String?>(null)
    var signingIn by mutableStateOf<String?>(null)
    private var chosen by mutableStateOf("youtube")

    /** Si la persona ya tocó una pestaña de servicio desde que abrió la app. */
    private var picked = false

    /** El servicio con el que abre la app: el último elegido que no sea la música del teléfono. */
    private val favorite: String
        get() = if (::app.isInitialized) preferences.getString("selected", null) ?: "youtube" else "youtube"

    /** El servicio elegido arriba. Se recuerda para abrir la app directamente en él. */
    var selected: String
        get() = chosen
        set(value) {
            chosen = value
            picked = true
            if (value != "local" && ::app.isInitialized) preferences.edit().putString("selected", value).apply()
        }

    /** Mientras se recuperan las sesiones guardadas al abrir la app. */
    var restoring by mutableStateOf(false)
        private set
    var session by mutableStateOf<SessionInfo?>(null)
    var sessionBusy by mutableStateOf(false)
    var audio by mutableStateOf<AudioSettings?>(null)
    var adding by mutableStateOf<PendingAdd?>(null)
    var sharing by mutableStateOf<ShareTarget?>(null)
    var libraryRevision by mutableIntStateOf(0)

    val signedIn: List<ProviderInfo> get() = providers.filter { it.signedIn }

    fun start(context: Context) {
        if (::engine.isInitialized) return
        app = context.applicationContext
        chosen = preferences.getString("selected", null) ?: chosen
        engine = Engine(this)
        state = engine.state()
        val saved = savedAudio()
        if (saved != null) engine.setAudioSettings(saved)
        audio = saved ?: engine.audioSettings()
        refresh()
        loadRecent()
        loadLook()
        Discord.load(app)
        watchNetwork()
        restoreStored()
        // la música del teléfono aparece sola si ya hay permiso (salvo que se haya quitado)
        if (!preferences.getBoolean("local.off", false) && canReadMusic()) openLocal(quiet = true)
        minter.start()
    }

    fun refresh() {
        providers = engine.providers()
        // al abrir, la música del teléfono suele estar lista antes que YouTube Music; cuando
        // llega el servicio de siempre, vuelve a ser el elegido salvo que la persona haya
        // tocado otra pestaña
        val preferred = favorite
        when {
            !picked && preferred != selected && signedIn.any { it.slug == preferred } -> chosen = preferred
            signedIn.none { it.slug == selected } ->
                (signedIn.firstOrNull { it.slug != "local" } ?: signedIn.firstOrNull())?.let { chosen = it.slug }
        }
        // Android Auto vuelve a leer la lista de servicios
        PlaybackService.instance?.notifyChildrenChanged(AutoBrowser.ROOT)
    }

    /** Corre algo que bloquea al motor fuera del hilo principal. */
    suspend fun <T> run(work: (Engine) -> T): Result<T> =
        withContext(Dispatchers.IO) { runCatching { work(engine) } }

    private fun launch(block: suspend () -> Unit) {
        scope.launch { block() }
    }

    private fun restoreStored() {
        val stored = providers.filter { it.stored && !it.signedIn }
        var pending = stored.size
        restoring = pending > 0
        for (provider in stored) {
            launch {
                run { it.restore(provider.slug) }.onFailure {
                    // sin internet no se avisa: lo descargado suena igual
                    if (online) problem = "${provider.name}: ${describe(it)}"
                }
                refresh()
                pending--
                if (pending == 0) restoring = false
            }
        }
    }

    // ── Cuentas ────────────────────────────────────────────────────────────────────────────

    fun signIn(provider: ProviderInfo, method: SignInMethod) {
        signingIn = provider.slug
        launch {
            val result = run { it.signIn(provider.slug, method) }
            signingIn = null
            prompt = null
            result.onSuccess {
                selected = provider.slug
                comeBack()
            }.onFailure { problem = describe(it) }
            refresh()
        }
    }

    /** Tras iniciar sesión en el navegador, intenta traer Sonora de vuelta al frente. */
    private fun comeBack() {
        runCatching {
            app.startActivity(
                android.content.Intent(app, MainActivity::class.java).addFlags(
                    android.content.Intent.FLAG_ACTIVITY_NEW_TASK or android.content.Intent.FLAG_ACTIVITY_CLEAR_TOP or
                        android.content.Intent.FLAG_ACTIVITY_SINGLE_TOP,
                ),
            )
        }
    }

    fun cancelSignIn() {
        engine.cancelSignIn()
        prompt = null
    }

    fun answer(text: String) = engine.sendInput(text)

    fun signOut(slug: String) {
        engine.signOut(slug)
        refresh()
    }

    // ── Reproducción ───────────────────────────────────────────────────────────────────────

    fun play(tracks: List<TrackItem>, index: Int, slug: String) = launch {
        run { it.playQueue(slug, tracks, index.toUInt()) }.onFailure { problem = describe(it) }
    }

    fun enqueue(tracks: List<TrackItem>, next: Boolean, slug: String) = launch {
        run { it.enqueue(slug, tracks, next) }.onFailure { problem = describe(it) }
    }

    /**
     * Toca una canción y detrás pone las parecidas en género y ritmo (la radio de esa canción),
     * en vez de la lista donde estaba. Suena enseguida; las parecidas llegan un momento después.
     */
    fun playSimilar(track: TrackItem, slug: String) = launch {
        run { it.playQueue(slug, listOf(track), 0u) }.onFailure {
            problem = describe(it)
            return@launch
        }
        run { it.radio(slug, track.id) }.onSuccess { found ->
            val rest = found.filter { it.id != track.id }
            // si mientras tanto se puso otra cosa, no se toca esa cola
            if (rest.isNotEmpty() && state?.track?.id == track.id) {
                run { it.enqueue(slug, rest, false) }
            }
        }
    }

    fun startRadio(track: TrackItem, slug: String) = launch {
        run { it.radio(slug, track.id) }
            .onSuccess { found ->
                val queue = if (found.any { it.id == track.id }) found else listOf(track) + found
                play(queue, 0, slug)
            }
            .onFailure { problem = describe(it) }
    }

    fun save(kind: SavedKind, id: String, slug: String, saved: Boolean = true, quiet: Boolean = false) = launch {
        run { it.setSaved(slug, kind, id, saved) }
            .onSuccess {
                if (!quiet) problem = if (saved) "Guardado en tu biblioteca." else "Quitado de tu biblioteca."
            }
            .onFailure { problem = describe(it) }
    }

    // ── Descargas para escuchar sin internet ───────────────────────────────────────────────

    /** Las canciones que se están descargando ahora, por id. */
    val downloading = mutableStateListOf<String>()

    /** Sube cada vez que cambia lo descargado, para que las pantallas vuelvan a preguntar. */
    var downloadRevision by mutableIntStateOf(0)

    /** Solo las canciones de YouTube Music se pueden descargar y escuchar sin conexión. */
    fun canDownload(slug: String) = slug == "youtube"

    fun isDownloaded(track: TrackItem, slug: String): Boolean =
        canDownload(slug) && runCatching { engine.isDownloaded(slug, track.id) }.getOrDefault(false)

    /** Descarga las canciones una tras otra para escucharlas sin internet. */
    fun download(tracks: List<TrackItem>, slug: String) = launch {
        val pending = tracks.filter { it.id !in downloading }
        if (pending.isEmpty()) return@launch
        pending.forEach { downloading.add(it.id) }
        if (pending.size > 1) problem = "Guardando ${pending.size} canciones para sin conexión…"
        var done = 0
        var failure: Throwable? = null
        for (track in pending) {
            run { it.downloadTrack(slug, track) }
                .onSuccess { done++ }
                .onFailure { failure = it }
            downloading.remove(track.id)
            downloadRevision++
        }
        problem = when {
            failure != null && done == 0 -> "No se pudo guardar para sin conexión: ${describe(failure!!)}"
            failure != null -> "Se guardaron $done de ${pending.size} canciones."
            pending.size == 1 -> "Guardada: ya suena sin conexión."
            else -> "Listo: $done canciones guardadas para sin conexión."
        }
    }

    fun removeDownload(track: TrackItem, slug: String) = launch {
        run { it.removeDownload(slug, track.id) }
        downloadRevision++
        problem = "Quitada de sin conexión."
    }

    // ── Playlists ──────────────────────────────────────────────────────────────────────────

    fun createPlaylist(name: String, slug: String) = launch {
        val clean = name.trim()
        if (clean.isEmpty()) return@launch
        run { it.createPlaylist(slug, clean) }
            .onSuccess { libraryRevision++ }
            .onFailure { problem = describe(it) }
    }

    suspend fun renamePlaylist(id: String, name: String, slug: String): Boolean =
        run { it.renamePlaylist(slug, id, name.trim()) }
            .onSuccess { libraryRevision++ }
            .onFailure { problem = describe(it) }
            .isSuccess

    suspend fun deletePlaylist(id: String, slug: String): Boolean =
        run { it.deletePlaylist(slug, id) }
            .onSuccess { libraryRevision++ }
            .onFailure { problem = describe(it) }
            .isSuccess

    fun addToPlaylist(playlist: PlaylistItem, pending: PendingAdd) = launch {
        adding = null
        run { it.addToPlaylist(pending.slug, playlist.id, pending.tracks.map { track -> track.id }) }
            .onSuccess {
                problem = "Agregada a «${playlist.title}»."
                libraryRevision++
            }
            .onFailure { problem = describe(it) }
    }

    suspend fun removeFromPlaylist(playlist: String, track: String, slug: String): Boolean =
        run { it.removeFromPlaylist(slug, playlist, track) }
            .onFailure { problem = describe(it) }
            .isSuccess

    fun createPlaylistAndAdd(name: String, pending: PendingAdd) = launch {
        val clean = name.trim()
        if (clean.isEmpty()) return@launch
        adding = null
        run {
            val id = it.createPlaylist(pending.slug, clean)
            it.addToPlaylist(pending.slug, id, pending.tracks.map { track -> track.id })
        }
            .onSuccess {
                problem = "Creada «$clean» y agregada."
                libraryRevision++
            }
            .onFailure { problem = describe(it) }
    }

    suspend fun setPlaylistPublic(id: String, public: Boolean, slug: String): Boolean =
        run { it.setPlaylistPublic(slug, id, public) }
            .onSuccess { libraryRevision++ }
            .onFailure { problem = describe(it) }
            .isSuccess

    suspend fun setPlaylistCover(id: String, image: ByteArray?, slug: String): Boolean =
        run { it.setPlaylistCover(slug, id, image) }
            .onSuccess { libraryRevision++ }
            .onFailure { problem = describe(it) }
            .isSuccess

    fun canSetPlaylistCover(slug: String): Boolean =
        runCatching { engine.canSetPlaylistCover(slug) }.getOrDefault(false)

    // ── Compartir ──────────────────────────────────────────────────────────────────────────

    fun share(
        slug: String,
        kind: SavedKind,
        id: String,
        title: String,
        subtitle: String,
        cover: String?,
        track: TrackItem? = null,
    ) = launch {
        val url = run { it.shareUrl(slug, kind, id) }.getOrNull()
        if (url.isNullOrBlank()) {
            problem = "Este elemento no tiene un enlace para compartir."
        } else {
            sharing = ShareTarget(
                title = title,
                subtitle = subtitle,
                cover = cover,
                url = url,
                round = kind == SavedKind.ARTIST,
                slug = slug,
                track = track,
            )
        }
    }

    // ── Sesiones ───────────────────────────────────────────────────────────────────────────

    fun startSession(slug: String = selected) {
        sessionBusy = true
        launch {
            run { it.sessionStart(slug) }.onFailure {
                problem = describe(it)
                sessionBusy = false
            }
        }
    }

    fun joinSession(code: String, remote: Boolean) {
        sessionBusy = true
        launch {
            run { it.sessionJoin(code, remote) }.onFailure {
                problem = describe(it)
                sessionBusy = false
            }
        }
    }

    /** Cierra Sonora del todo: sale de la sesión, para la música y termina el proceso. */
    fun shutdown() {
        runCatching {
            if (session != null) engine.sessionLeave()
            engine.pause()
        }
        PlaybackService.instance?.let {
            it.stopForeground(android.app.Service.STOP_FOREGROUND_REMOVE)
            it.stopSelf()
        }
        main.postDelayed({ android.os.Process.killProcess(android.os.Process.myPid()) }, 300)
    }

    // ── Personalización ────────────────────────────────────────────────────────────────────

    var palette by mutableStateOf(Palette.SYSTEM)
        private set
    var mode by mutableStateOf(Mode.SYSTEM)
        private set
    /** El nombre del saludo de Inicio («Hola, …»). */
    var userName by mutableStateOf("")
        private set

    private fun loadLook() {
        palette = runCatching { Palette.valueOf(preferences.getString("look.palette", "")!!) }.getOrDefault(Palette.SYSTEM)
        mode = runCatching { Mode.valueOf(preferences.getString("look.mode", "")!!) }.getOrDefault(Mode.SYSTEM)
        userName = preferences.getString("look.name", "")!!
        // Lo de la música del teléfono también se lee aquí: los ajustes solo existen tras init.
        hiddenFolders = preferences.getStringSet("local.hidden", null)?.sorted() ?: emptyList()
        skipWhatsapp = preferences.getBoolean("local.whatsapp", true)
        showRomanized = preferences.getBoolean("lyrics.romanized", true)
        lyricStyle = runCatching { LyricStyle.valueOf(preferences.getString("lyrics.style", "")!!) }.getOrDefault(LyricStyle.ENFOQUE)
        lyricBackdrop = runCatching { LyricBackdrop.valueOf(preferences.getString("lyrics.backdrop", "")!!) }.getOrDefault(LyricBackdrop.PORTADA)
        lyricSize = preferences.getFloat("lyrics.size", 1f)
        lyricStart = preferences.getBoolean("lyrics.start", false)
        lyricWhite = preferences.getBoolean("lyrics.white", false)
        lyricsOnStage = preferences.getBoolean("lyrics.stage", false)
        lyricsInBar = preferences.getBoolean("lyrics.bar", true)
        dockEnabled = preferences.getBoolean("dock.enabled", false)
        visualStyle = runCatching { VisualStyle.valueOf(preferences.getString("visual.style", "")!!) }.getOrDefault(VisualStyle.ONDAS)
        visualColor = runCatching { VisualColor.valueOf(preferences.getString("visual.color", "")!!) }.getOrDefault(VisualColor.PORTADA)
        visualCalm = preferences.getBoolean("visual.calm", false)
        visualBehind = preferences.getBoolean("visual.behind", false)
        visualInBar = preferences.getBoolean("visual.bar", false)
        offlineMode = preferences.getBoolean("offline.mode", false)
        adaptive = preferences.getBoolean("look.adaptive", false)
        ambient = preferences.getBoolean("look.ambient", true)
        visualizer = runCatching { VisualizerStyle.valueOf(preferences.getString("look.visualizer", "")!!) }
            .getOrDefault(VisualizerStyle.BARS)
    }

    fun choosePalette(value: Palette) {
        palette = value
        preferences.edit().putString("look.palette", value.name).apply()
    }

    fun chooseMode(value: Mode) {
        mode = value
        preferences.edit().putString("look.mode", value.name).apply()
    }

    fun rename(value: String) {
        userName = value.trim()
        preferences.edit().putString("look.name", userName).apply()
    }

    // ── Búsquedas recientes ────────────────────────────────────────────────────────────────

    var recent by mutableStateOf(listOf<String>())
        private set

    private fun loadRecent() {
        recent = preferences.getString("search.recent", "")!!.split("\n").filter { it.isNotBlank() }
    }

    /** Guarda una búsqueda (la más nueva primero, sin repetir, hasta 12). */
    fun remember(text: String) {
        recent = (listOf(text) + recent.filterNot { it.equals(text, ignoreCase = true) }).take(12)
        preferences.edit().putString("search.recent", recent.joinToString("\n")).apply()
    }

    fun forget(text: String) {
        recent = recent - text
        preferences.edit().putString("search.recent", recent.joinToString("\n")).apply()
    }

    // ── Canciones del teléfono ─────────────────────────────────────────────────────────────

    var localBusy by mutableStateOf(false)

    /** El permiso para leer la música del teléfono (cambia de nombre en Android 13). */
    val musicPermission: String
        get() = if (android.os.Build.VERSION.SDK_INT >= 33) android.Manifest.permission.READ_MEDIA_AUDIO
        else android.Manifest.permission.READ_EXTERNAL_STORAGE

    fun canReadMusic() = androidx.core.content.ContextCompat.checkSelfPermission(app, musicPermission) ==
        android.content.pm.PackageManager.PERMISSION_GRANTED

    /** Las carpetas con música que se están mirando, para mostrarlas en Ajustes. */
    var localFolders by mutableStateOf(listOf<String>())
        private set

    /** Las carpetas que se agregaron a mano, además de las que conoce Android. */
    private val extraFolders: Set<String>
        get() = preferences.getStringSet("local.extra", null) ?: emptySet()

    fun addLocalFolder(path: String) {
        preferences.edit().putStringSet("local.extra", extraFolders + path).apply()
        openLocal()
    }

    /** Las carpetas que la persona quitó: no se miran, ni lo que tienen dentro. */
    var hiddenFolders by mutableStateOf(emptyList<String>())
        private set

    /** Si se dejan fuera las notas de voz y los audios de WhatsApp (por defecto, sí). */
    var skipWhatsapp by mutableStateOf(true)
        private set

    /** Si el teléfono tiene internet ahora mismo (lo avisa Android al cambiar). */
    var online by mutableStateOf(true)
        private set

    /** El modo sin conexión elegido a mano en Ajustes, aunque haya internet (para ahorrar datos). */
    var offlineMode by mutableStateOf(false)
        private set

    /** Si la app se muestra sin conexión: sin internet, o con el modo puesto a mano. */
    val offline get() = !online || offlineMode

    fun changeOfflineMode(on: Boolean) {
        offlineMode = on
        preferences.edit().putBoolean("offline.mode", on).apply()
    }

    /** Sigue la conexión a internet del teléfono para pasar solo al modo sin conexión y volver. */
    private fun watchNetwork() {
        val manager = app.getSystemService(Context.CONNECTIVITY_SERVICE) as? android.net.ConnectivityManager ?: return
        // si Android no deja mirar la red, se asume que hay conexión (nunca debe tumbar la app)
        fun connected(): Boolean = runCatching {
            val network = manager.activeNetwork ?: return@runCatching false
            val abilities = manager.getNetworkCapabilities(network) ?: return@runCatching false
            abilities.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET)
        }.getOrDefault(true)
        online = connected()
        runCatching {
            manager.registerDefaultNetworkCallback(object : android.net.ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: android.net.Network) {
                    scope.launch { online = true }
                }
                override fun onLost(network: android.net.Network) {
                    scope.launch { online = connected() }
                }
            })
        }
    }

    /** «Colores de la portada»: el color de lo que suena tiñe toda la app. */
    var adaptive by mutableStateOf(false)
        private set

    /** El color sacado de la portada de lo que suena, para el tema adaptativo. */
    var coverAccent by mutableStateOf<androidx.compose.ui.graphics.Color?>(null)

    /** «Fondo ambiental»: los colores de la portada se mueven despacio detrás del reproductor. */
    var ambient by mutableStateOf(true)
        private set

    /** Cómo se dibuja el visualizador. */
    var visualizer by mutableStateOf(VisualizerStyle.BARS)
        private set

    fun changeAdaptive(on: Boolean) {
        adaptive = on
        preferences.edit().putBoolean("look.adaptive", on).apply()
    }

    fun changeAmbient(on: Boolean) {
        ambient = on
        preferences.edit().putBoolean("look.ambient", on).apply()
    }

    fun chooseVisualizer(style: VisualizerStyle) {
        visualizer = style
        preferences.edit().putString("look.visualizer", style.name).apply()
    }

    /** Si se muestra la pronunciación de las letras en otros sistemas de escritura. */
    var showRomanized by mutableStateOf(true)
        private set

    fun changeShowRomanized(show: Boolean) {
        showRomanized = show
        preferences.edit().putBoolean("lyrics.romanized", show).apply()
    }

    // ── Letras ────────────────────────────────────────────────────────────────────────────

    /** Cómo se anima la letra sincronizada. */
    var lyricStyle by mutableStateOf(LyricStyle.ENFOQUE)
        private set
    /** Qué va detrás de la letra. */
    var lyricBackdrop by mutableStateOf(LyricBackdrop.PORTADA)
        private set
    /** El tamaño de la letra: 0,82 chica, 1 normal, 1,2 grande. */
    var lyricSize by mutableStateOf(1f)
        private set
    /** La letra a la izquierda en vez de al centro. */
    var lyricStart by mutableStateOf(false)
        private set
    /** Resaltar en blanco en vez del color de la portada. */
    var lyricWhite by mutableStateOf(false)
        private set
    /** La línea que suena encima de la pantalla completa. */
    var lyricsOnStage by mutableStateOf(false)
        private set
    /** La línea que suena en la barra de abajo, en vez del artista. */
    var lyricsInBar by mutableStateOf(true)
        private set

    fun chooseLyricStyle(style: LyricStyle) {
        lyricStyle = style
        preferences.edit().putString("lyrics.style", style.name).apply()
    }

    fun chooseLyricBackdrop(backdrop: LyricBackdrop) {
        lyricBackdrop = backdrop
        preferences.edit().putString("lyrics.backdrop", backdrop.name).apply()
    }

    fun changeLyricSize(size: Float) {
        lyricSize = size
        preferences.edit().putFloat("lyrics.size", size).apply()
    }

    fun changeLyricStart(start: Boolean) {
        lyricStart = start
        preferences.edit().putBoolean("lyrics.start", start).apply()
    }

    fun changeLyricWhite(white: Boolean) {
        lyricWhite = white
        preferences.edit().putBoolean("lyrics.white", white).apply()
    }

    fun changeLyricsOnStage(on: Boolean) {
        lyricsOnStage = on
        preferences.edit().putBoolean("lyrics.stage", on).apply()
    }

    // ── Visuales ──────────────────────────────────────────────────────────────────────────

    /** El visual de la pantalla completa. */
    var visualStyle by mutableStateOf(VisualStyle.ONDAS)
        private set
    /** Los colores de los visuales: los de la portada o un arcoíris. */
    var visualColor by mutableStateOf(VisualColor.PORTADA)
        private set
    /** Los visuales más lentos y sin saltos fuertes. */
    var visualCalm by mutableStateOf(false)
        private set
    /** El visual, tenue, detrás del reproductor. */
    var visualBehind by mutableStateOf(false)
        private set
    /** Una franja del visual en la barra de abajo. */
    var visualInBar by mutableStateOf(false)
        private set

    fun chooseVisualStyle(style: VisualStyle) {
        visualStyle = style
        preferences.edit().putString("visual.style", style.name).apply()
    }

    fun chooseVisualColor(color: VisualColor) {
        visualColor = color
        preferences.edit().putString("visual.color", color.name).apply()
    }

    fun changeVisualCalm(on: Boolean) {
        visualCalm = on
        preferences.edit().putBoolean("visual.calm", on).apply()
    }

    fun changeVisualBehind(on: Boolean) {
        visualBehind = on
        preferences.edit().putBoolean("visual.behind", on).apply()
    }

    fun changeVisualInBar(on: Boolean) {
        visualInBar = on
        preferences.edit().putBoolean("visual.bar", on).apply()
    }

    /** El dock flotante sobre otras apps (apagado hasta que se active). */
    var dockEnabled by mutableStateOf(false)
        private set

    fun changeDockEnabled(on: Boolean) {
        dockEnabled = on
        preferences.edit().putBoolean("dock.enabled", on).apply()
    }

    fun changeLyricsInBar(on: Boolean) {
        lyricsInBar = on
        preferences.edit().putBoolean("lyrics.bar", on).apply()
    }

    /** Quita una carpeta de la música: la agregada a mano se olvida, la que halló Android se oculta. */
    fun removeLocalFolder(path: String) {
        if (path in extraFolders) {
            preferences.edit().putStringSet("local.extra", extraFolders - path).apply()
        } else {
            hiddenFolders = (hiddenFolders + path).distinct().sorted()
            preferences.edit().putStringSet("local.hidden", hiddenFolders.toSet()).apply()
        }
        openLocal()
    }

    /** Vuelve a mirar una carpeta que se había quitado. */
    fun showLocalFolder(path: String) {
        hiddenFolders = hiddenFolders - path
        preferences.edit().putStringSet("local.hidden", hiddenFolders.toSet()).apply()
        openLocal()
    }

    fun changeSkipWhatsapp(skip: Boolean) {
        skipWhatsapp = skip
        preferences.edit().putBoolean("local.whatsapp", skip).apply()
        openLocal()
    }

    /** Si la carpeta queda fuera por una regla: quitada a mano, dentro de una quitada o de WhatsApp. */
    private fun leftOut(path: String) =
        hiddenFolders.any { path == it || path.startsWith("$it/") } ||
            (skipWhatsapp && path.split('/').any { it.contains("whatsapp", ignoreCase = true) })

    /**
     * Las carpetas donde hay música, según el índice de Android (el mismo que usan las apps de
     * música, como BoomingMusic): así aparecen solas todas las canciones del teléfono, estén donde
     * estén. Se quitan las que están dentro de otra, porque cada una se recorre con sus subcarpetas.
     */
    private fun musicFolders(): List<String> {
        val found = mutableSetOf<String>()
        runCatching {
            app.contentResolver.query(
                android.provider.MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
                arrayOf(android.provider.MediaStore.Audio.Media.DATA),
                // todo el audio menos tonos, alarmas y notificaciones: Android no marca como
                // «música» mucho de lo que se baja con el navegador u otras apps
                "${android.provider.MediaStore.Audio.Media.IS_RINGTONE} = 0 AND " +
                    "${android.provider.MediaStore.Audio.Media.IS_ALARM} = 0 AND " +
                    "${android.provider.MediaStore.Audio.Media.IS_NOTIFICATION} = 0",
                null,
                null,
            )?.use { cursor ->
                val column = cursor.getColumnIndexOrThrow(android.provider.MediaStore.Audio.Media.DATA)
                var count = 0
                while (cursor.moveToNext()) {
                    cursor.getString(column)?.let { path ->
                        if (!leftOut(path)) count++
                        java.io.File(path).parent?.let(found::add)
                    }
                }
                androidAudio = count
            }
        }
        // Música y Descargas siempre, en la memoria interna y en cada tarjeta SD, aunque Android
        // todavía no haya registrado lo que hay dentro
        val usual = buildList {
            add(android.os.Environment.getExternalStoragePublicDirectory(android.os.Environment.DIRECTORY_MUSIC).path)
            add(android.os.Environment.getExternalStoragePublicDirectory(android.os.Environment.DIRECTORY_DOWNLOADS).path)
            app.getExternalFilesDirs(null).filterNotNull().drop(1).forEach { own ->
                // …/Android/data/<app>/files → la raíz de la tarjeta
                val root = own.path.substringBefore("/Android/")
                add("$root/${android.os.Environment.DIRECTORY_MUSIC}")
                add("$root/${android.os.Environment.DIRECTORY_DOWNLOADS}")
            }
        }.filter { java.io.File(it).isDirectory }
        val all = (found + extraFolders + usual).map { it.trimEnd('/') }.distinct().filterNot(::leftOut).sorted()
        val outer = mutableListOf<String>()
        for (path in all) if (outer.none { path == it || path.startsWith("$it/") }) outer += path
        return outer
    }

    /** Cuántos audios dice Android que hay (sin WhatsApp ni carpetas quitadas), para comparar. */
    @Volatile private var androidAudio = 0

    /** Lo encontrado en la última búsqueda: canciones en la app y audios que ve Android. */
    var localFound by mutableStateOf<Pair<Int, Int>?>(null)
        private set

    /** Busca (o vuelve a buscar) las canciones del teléfono. */
    fun openLocal(quiet: Boolean = false) {
        localBusy = true
        launch {
            val folders = withContext(Dispatchers.IO) { musicFolders() }
            localFolders = folders
            run {
                it.setLocalSkip(hiddenFolders, skipWhatsapp)
                it.openLocal(folders)
            }
                .onSuccess { preferences.edit().putBoolean("local.off", false).apply() }
                .onFailure { if (!quiet) problem = describe(it) }
            val inApp = run { it.libraryTracks("local").size }.getOrDefault(0)
            localFound = inApp to androidAudio
            localBusy = false
            libraryRevision++
            refresh()
        }
    }

    fun closeLocal() {
        preferences.edit().putBoolean("local.off", true).apply()
        signOut("local")
    }

    // ── Scrobbling ─────────────────────────────────────────────────────────────────────────

    suspend fun linkScrobble(id: String, key: String, secret: String, token: String, server: String): Boolean {
        val result = run { it.scrobbleConnect(id, key, secret, token, server) }
        prompt = null
        result.onFailure { problem = describe(it) }
        return result.isSuccess
    }

    // ── Ajustes de audio ───────────────────────────────────────────────────────────────────

    private val preferences get() = app.getSharedPreferences("sonora", Context.MODE_PRIVATE)

    private fun savedAudio(): AudioSettings? {
        val prefs = preferences
        if (!prefs.contains("audio.quality")) return null
        val quality = runCatching { AudioQuality.valueOf(prefs.getString("audio.quality", "HIGH")!!) }
            .getOrDefault(AudioQuality.HIGH)
        val bands = prefs.getString("audio.bands", "")!!
            .split(",").mapNotNull { it.toDoubleOrNull() }
            .let { if (it.size == 10) it else List(10) { 0.0 } }
        return AudioSettings(
            quality = quality,
            normalisation = prefs.getBoolean("audio.normalisation", true),
            gapless = prefs.getBoolean("audio.gapless", true),
            equalizer = prefs.getBoolean("audio.equalizer", false),
            bands = bands,
        )
    }

    fun applyAudio(settings: AudioSettings) {
        audio = settings
        preferences.edit()
            .putString("audio.quality", settings.quality.name)
            .putBoolean("audio.normalisation", settings.normalisation)
            .putBoolean("audio.gapless", settings.gapless)
            .putBoolean("audio.equalizer", settings.equalizer)
            .putString("audio.bands", settings.bands.joinToString(","))
            .apply()
        launch { run { it.setAudioSettings(settings) } }
    }

    // ── Avisos del motor (llegan desde hilos de Rust) ──────────────────────────────────────

    override fun onPrompt(slug: String, prompt: Prompt) {
        main.post { this.prompt = PendingPrompt(slug, prompt) }
    }

    override fun onState(state: PlaybackState) {
        main.post {
            this.state = state
            PlaybackService.update(app, state)
        }
    }

    override fun onProblem(message: String) {
        main.post {
            problem = message
            sessionBusy = false
        }
    }

    override fun onSession(session: SessionInfo?) {
        main.post {
            this.session = session
            if (session != null) sessionBusy = false
        }
    }
}

/** El mensaje de un error del motor. */
fun describe(error: Throwable): String = error.message ?: error.toString()

/** `1:05` para 65 000 ms. */
fun clock(milliseconds: ULong): String {
    val seconds = (milliseconds / 1000u).toLong()
    return "%d:%02d".format(seconds / 60, seconds % 60)
}

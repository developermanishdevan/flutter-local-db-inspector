package com.manishdevan.flutterdb.ui.web

/**
 * The shared web UI bundled at `/web-ui/` in the plugin jar (built from
 * `shared/web-ui` by the `buildWebUi` Gradle task) and served to JCEF from
 * the private origin [ORIGIN], so the page's CSP (`'self'`) covers its
 * scripts, styles and fonts.
 */
object WebUiResources {
    /** Never resolved by DNS: every request to it is answered by [WebUiRequestHandler]. */
    const val ORIGIN = "https://fdi-web-ui/"
    const val INDEX_URL = "${ORIGIN}index.html"
    private const val ROOT = "/web-ui/"

    class Resource(val bytes: ByteArray, val mimeType: String)

    /** False when the plugin was built with `-PskipWebUi`. */
    fun isAvailable(): Boolean = WebUiResources::class.java.getResource("${ROOT}index.html") != null

    /**
     * The resource for [url], or null if it isn't a web UI URL or doesn't
     * exist. `index.html` gets [theme] as `data-theme` so the first paint
     * already matches the IDE.
     */
    fun load(url: String, theme: String): Resource? {
        val path = pathOf(url) ?: return null
        val bytes = WebUiResources::class.java.getResourceAsStream(ROOT + path)?.use { it.readBytes() } ?: return null
        val content = if (path == "index.html") withTheme(bytes.toString(Charsets.UTF_8), theme).toByteArray() else bytes
        return Resource(content, mimeType(path))
    }

    /** `https://fdi-web-ui/a/b.css?x#y` → `a/b.css`; null outside [ORIGIN] or for `..` paths. */
    fun pathOf(url: String): String? {
        if (!url.startsWith(ORIGIN)) return null
        val path = url.removePrefix(ORIGIN).substringBefore('#').substringBefore('?').ifEmpty { "index.html" }
        val segments = path.split('/')
        if (segments.any { it.isEmpty() || it == "." || it == ".." || '\\' in it }) return null
        return path
    }

    fun withTheme(html: String, theme: String): String =
        html.replaceFirst(Regex("<html(\\s|>)"), "<html data-theme=\"$theme\"$1")

    fun mimeType(path: String): String = when (path.substringAfterLast('.', "").lowercase()) {
        "html", "htm" -> "text/html"
        "js", "mjs" -> "text/javascript"
        "css" -> "text/css"
        "json", "map" -> "application/json"
        "svg" -> "image/svg+xml"
        "png" -> "image/png"
        "ttf" -> "font/ttf"
        "woff" -> "font/woff"
        "woff2" -> "font/woff2"
        else -> "application/octet-stream"
    }
}

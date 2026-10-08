package com.manishdevan.flutterdb.connection

import java.net.URI
import java.net.URLDecoder
import java.nio.charset.StandardCharsets

/** VM service URI handling shared by manual connect and run-console discovery. */
object VmServiceUri {
    private val EMBEDDED = Regex("[?&]uri=([^&\\s]+)")
    private val URL = Regex("(?:https?|wss?)://[^\\s\"'<>]+")
    private val ANSI = Regex("\u001B\\[[0-9;?]*[A-Za-z]")

    /** Console lines that announce a VM service (Flutter, Dart, Flutter daemon JSON). */
    private val ANNOUNCEMENTS = listOf(
        Regex("A Dart VM Service on .+? is available at:\\s*(\\S+)"),
        Regex("The Dart VM service is listening on\\s+(\\S+)"),
        Regex("Observatory listening on\\s+(\\S+)"),
        Regex("\"event\"\\s*:\\s*\"app\\.debugPort\".*?\"wsUri\"\\s*:\\s*\"([^\"]+)\""),
    )

    /**
     * Normalizes anything a user may paste — an `http://…/token=/` URI, a
     * `ws://…/ws` URI or a DevTools link containing `?uri=` — into the VM
     * service WebSocket URI. Throws [IllegalArgumentException] otherwise.
     */
    fun toWebSocketUri(input: String): String {
        var text = input.trim()
        EMBEDDED.find(text)?.let {
            text = URLDecoder.decode(it.groupValues[1].replace("+", "%2B"), StandardCharsets.UTF_8)
        }
        val found = URL.find(text) ?: throw IllegalArgumentException("\"$input\" does not contain a VM service URI")
        val uri = try {
            URI(found.value)
        } catch (e: Exception) {
            throw IllegalArgumentException("\"${found.value}\" is not a valid URI", e)
        }
        val scheme = when (uri.scheme.lowercase()) {
            "http" -> "ws"
            "https" -> "wss"
            else -> uri.scheme.lowercase()
        }
        val authority = uri.rawAuthority?.takeIf { it.isNotEmpty() }
            ?: throw IllegalArgumentException("\"${found.value}\" has no host")
        var path = uri.rawPath.orEmpty().ifEmpty { "/" }
        if (!path.endsWith("/ws")) path = "${if (path.endsWith("/")) path else "$path/"}ws"
        return "$scheme://${authority.lowercase()}$path"
    }

    /** Extracts the VM service URI announced by one line of console output, if any. */
    fun fromConsoleLine(line: String): String? {
        val clean = ANSI.replace(line, "")
        for (pattern in ANNOUNCEMENTS) {
            val raw = pattern.find(clean)?.groupValues?.get(1) ?: continue
            return try {
                toWebSocketUri(raw)
            } catch (_: IllegalArgumentException) {
                null
            }
        }
        return null
    }

    /** Short label for a URI, e.g. `127.0.0.1:50300`. */
    fun label(wsUri: String): String = try {
        URI(wsUri).rawAuthority ?: wsUri
    } catch (_: Exception) {
        wsUri
    }
}

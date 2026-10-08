package com.manishdevan.flutterdb.ui.web

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

class WebUiResourcesTest {
    @Test
    fun `paths are resolved only inside the origin`() {
        assertEquals("index.html", WebUiResources.pathOf("https://fdi-web-ui/"))
        assertEquals("index.html", WebUiResources.pathOf("https://fdi-web-ui/index.html?x=1#top"))
        assertEquals("codicons/codicon.ttf", WebUiResources.pathOf("https://fdi-web-ui/codicons/codicon.ttf?5d4d76ab"))
        assertNull(WebUiResources.pathOf("https://example.com/index.html"))
        assertNull(WebUiResources.pathOf("https://fdi-web-ui/../META-INF/plugin.xml"))
        assertNull(WebUiResources.pathOf("https://fdi-web-ui/codicons/../../x"))
        assertNull(WebUiResources.pathOf("https://fdi-web-ui//etc/passwd"))
        assertNull(WebUiResources.load("https://fdi-web-ui/missing.js", "light"))
    }

    @Test
    fun `mime types`() {
        assertEquals("text/html", WebUiResources.mimeType("index.html"))
        assertEquals("text/javascript", WebUiResources.mimeType("inspector.js"))
        assertEquals("text/css", WebUiResources.mimeType("codicons/codicon.css"))
        assertEquals("font/ttf", WebUiResources.mimeType("codicons/codicon.ttf"))
        assertEquals("image/svg+xml", WebUiResources.mimeType("a.SVG"))
        assertEquals("application/octet-stream", WebUiResources.mimeType("README"))
    }

    @Test
    fun `index html gets the IDE theme`() {
        assertEquals("<!doctype html>\n<html data-theme=\"dark\" lang=\"en\">", WebUiResources.withTheme("<!doctype html>\n<html lang=\"en\">", "dark"))
        assertEquals("<html data-theme=\"light\">", WebUiResources.withTheme("<html>", "light"))
    }

    @Test
    fun `bundled UI is served when built`() {
        // Absent when built with -PskipWebUi.
        assumeTrue(WebUiResources.isAvailable())
        val index = WebUiResources.load(WebUiResources.INDEX_URL, "dark")!!
        assertEquals("text/html", index.mimeType)
        val html = index.bytes.toString(Charsets.UTF_8)
        assertTrue(html, "data-theme=\"dark\"" in html)
        assertTrue(html, "inspector.js" in html)
        for (path in listOf("inspector.js", "inspector.css", "codicons/codicon.css", "codicons/codicon.ttf")) {
            val resource = WebUiResources.load(WebUiResources.ORIGIN + path, "dark")
            assertTrue(path, resource != null && resource.bytes.isNotEmpty())
        }
    }
}

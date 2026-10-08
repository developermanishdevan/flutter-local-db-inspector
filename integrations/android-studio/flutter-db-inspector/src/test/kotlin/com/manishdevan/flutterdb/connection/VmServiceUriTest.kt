package com.manishdevan.flutterdb.connection

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class VmServiceUriTest {
    @Test
    fun `normalizes VM service URIs from every source`() {
        assertEquals("ws://127.0.0.1:50300/abc=/ws", VmServiceUri.toWebSocketUri("http://127.0.0.1:50300/abc=/"))
        assertEquals("ws://127.0.0.1:50300/abc=/ws", VmServiceUri.toWebSocketUri("http://127.0.0.1:50300/abc="))
        assertEquals("ws://127.0.0.1:50300/abc=/ws", VmServiceUri.toWebSocketUri("ws://127.0.0.1:50300/abc=/ws"))
        assertEquals("wss://example.com/t=/ws", VmServiceUri.toWebSocketUri("https://example.com/t=/"))
        assertEquals("ws://127.0.0.1:1234/ws", VmServiceUri.toWebSocketUri("  http://127.0.0.1:1234  "))
        assertEquals(
            "ws://127.0.0.1:61234/x_Y-z=/ws",
            VmServiceUri.toWebSocketUri("The Dart VM service is listening on http://127.0.0.1:61234/x_Y-z=/"),
        )
        assertEquals(
            "ws://127.0.0.1:61234/tok=/ws",
            VmServiceUri.toWebSocketUri("http://127.0.0.1:9100/devtools/?uri=ws%3A%2F%2F127.0.0.1%3A61234%2Ftok%3D%2Fws"),
        )
    }

    @Test(expected = IllegalArgumentException::class)
    fun `rejects input without a URI`() {
        VmServiceUri.toWebSocketUri("not a uri")
    }

    @Test
    fun `finds announcements in run console output`() {
        assertEquals(
            "ws://127.0.0.1:50300/abc=/ws",
            VmServiceUri.fromConsoleLine("A Dart VM Service on sdk gphone64 arm64 is available at: http://127.0.0.1:50300/abc=/"),
        )
        assertEquals(
            "ws://127.0.0.1:8181/q1=/ws",
            VmServiceUri.fromConsoleLine("The Dart VM service is listening on http://127.0.0.1:8181/q1=/"),
        )
        assertEquals(
            "ws://127.0.0.1:8181/q1=/ws",
            VmServiceUri.fromConsoleLine("\u001B[1mA Dart VM Service on macOS is available at: \u001B[0mhttp://127.0.0.1:8181/q1=/"),
        )
        assertEquals(
            "ws://127.0.0.1:5555/dp=/ws",
            VmServiceUri.fromConsoleLine("""[{"event":"app.debugPort","params":{"appId":"x","port":5555,"wsUri":"ws://127.0.0.1:5555/dp=/ws","baseUri":"file:///"}}]"""),
        )
        assertNull(VmServiceUri.fromConsoleLine("The Flutter DevTools debugger and profiler on macOS is available at: http://127.0.0.1:9100?uri=ws://127.0.0.1:1/a=/ws"))
        assertNull(VmServiceUri.fromConsoleLine("flutter: hello"))
    }

    @Test
    fun `console scanner handles split lines and reports each URI once`() {
        val found = mutableListOf<String>()
        val scanner = RunConsoleDiscovery.ConsoleScanner("test") { found += it }
        scanner.accept("Launching…\nThe Dart VM service is liste")
        scanner.accept("ning on http://127.0.0.1:4000/a=/\r\n")
        scanner.accept("The Dart VM service is listening on http://127.0.0.1:4000/a=/\n")
        scanner.accept("A Dart VM Service on Pixel is available at: http://127.0.0.1:4001/b=/\n")
        assertEquals(listOf("ws://127.0.0.1:4000/a=/ws", "ws://127.0.0.1:4001/b=/ws"), found)
    }
}

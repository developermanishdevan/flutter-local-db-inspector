package com.manishdevan.flutterdb.ui.web

import com.intellij.ide.BrowserUtil
import org.cef.browser.CefBrowser
import org.cef.browser.CefFrame
import org.cef.callback.CefCallback
import org.cef.handler.CefLifeSpanHandlerAdapter
import org.cef.handler.CefRequestHandlerAdapter
import org.cef.handler.CefResourceHandler
import org.cef.handler.CefResourceHandlerAdapter
import org.cef.handler.CefResourceRequestHandler
import org.cef.handler.CefResourceRequestHandlerAdapter
import org.cef.misc.BoolRef
import org.cef.misc.IntRef
import org.cef.misc.StringRef
import org.cef.network.CefRequest
import org.cef.network.CefResponse

/**
 * Serves [WebUiResources] for requests to [WebUiResources.ORIGIN] from the
 * plugin jar (nothing is extracted to disk) and keeps the browser on that
 * origin: other resource loads are cancelled (on top of the page's CSP) and
 * other http(s) links open in the system browser.
 */
class WebUiRequestHandler(private val theme: () -> String) : CefRequestHandlerAdapter() {
    private val resources = object : CefResourceRequestHandlerAdapter() {
        override fun getResourceHandler(browser: CefBrowser?, frame: CefFrame?, request: CefRequest): CefResourceHandler? =
            if (request.url.startsWith(WebUiResources.ORIGIN)) BytesResourceHandler(WebUiResources.load(request.url, theme())) else null
    }

    override fun getResourceRequestHandler(
        browser: CefBrowser?,
        frame: CefFrame?,
        request: CefRequest,
        isNavigation: Boolean,
        isDownload: Boolean,
        requestInitiator: String?,
        disableDefaultHandling: BoolRef?,
    ): CefResourceRequestHandler? = when {
        request.url.startsWith(WebUiResources.ORIGIN) -> resources
        request.url.startsWith("data:") || request.url.startsWith("blob:") -> null
        else -> blocked
    }

    private val blocked = object : CefResourceRequestHandlerAdapter() {
        override fun onBeforeResourceLoad(browser: CefBrowser?, frame: CefFrame?, request: CefRequest?): Boolean = true
    }

    companion object {
        /** The page never opens windows (e.g. a modified click on an `href="#"` link). */
        val noPopups = object : CefLifeSpanHandlerAdapter() {
            override fun onBeforePopup(browser: CefBrowser?, frame: CefFrame?, targetUrl: String?, targetFrameName: String?): Boolean = true
        }
    }

    override fun onBeforeBrowse(browser: CefBrowser?, frame: CefFrame?, request: CefRequest, userGesture: Boolean, isRedirect: Boolean): Boolean {
        val url = request.url
        if (url.startsWith(WebUiResources.ORIGIN)) return false
        if (userGesture && (url.startsWith("https://") || url.startsWith("http://"))) BrowserUtil.browse(url)
        return true
    }
}

/**
 * Answers one request with [resource], or 404 when it is null.
 *
 * Extends [CefResourceHandlerAdapter] rather than implementing
 * [CefResourceHandler]: newer JCEF (2026.2+) adds abstract `open`/`read`/`skip`
 * to the interface, and the adapter implements them by falling back to
 * `processRequest`/`readResponse`, which are the only methods 2025.1 has.
 */
private class BytesResourceHandler(private val resource: WebUiResources.Resource?) : CefResourceHandlerAdapter() {
    private var offset = 0

    override fun processRequest(request: CefRequest, callback: CefCallback): Boolean {
        callback.Continue()
        return true
    }

    override fun getResponseHeaders(response: CefResponse, responseLength: IntRef, redirectUrl: StringRef) {
        if (resource == null) {
            response.status = 404
            response.statusText = "Not Found"
            response.mimeType = "text/plain"
            responseLength.set(0)
            return
        }
        response.status = 200
        response.statusText = "OK"
        response.mimeType = resource.mimeType
        // The resources change only with the plugin; never serve a stale copy after an update.
        response.setHeaderByName("Cache-Control", "no-store", true)
        response.setHeaderByName("X-Content-Type-Options", "nosniff", true)
        responseLength.set(resource.bytes.size)
    }

    override fun readResponse(dataOut: ByteArray, bytesToRead: Int, bytesRead: IntRef, callback: CefCallback): Boolean {
        val bytes = resource?.bytes
        if (bytes == null || offset >= bytes.size) {
            bytesRead.set(0)
            return false
        }
        val count = minOf(bytesToRead, bytes.size - offset)
        System.arraycopy(bytes, offset, dataOut, 0, count)
        offset += count
        bytesRead.set(count)
        return true
    }

    override fun cancel() {}
}

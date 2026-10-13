package com.manishdevan.flutterdb.connection

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Same cases as `appPackage.test.ts`; the three implementations must agree. */
class AppPackageTest {
    @Test
    fun `package uri gives the package name`() {
        assertEquals("sfa_app", appPackageOf("package:sfa_app/main.dart"))
        assertEquals("sfa_app", appPackageOf("package:sfa_app/src/entry/main_dev.dart"))
    }

    @Test
    fun `file uri gives the folder above lib`() {
        assertEquals("sfa_app", appPackageOf("file:///Users/me/work/sfa_app/lib/main_dev.dart"))
        assertEquals("sfa_app", appPackageOf("file:///C:/work/sfa_app/lib/src/main.dart?x=1#y"))
    }

    @Test
    fun `web root library uses the app's own main library`() {
        val libraries = listOf("dart:core", "package:flutter/material.dart", "package:shop/main.dart", "org-dartlang-app:///lib/main.dart")
        assertEquals("shop", appPackageOf("org-dartlang-app:///lib/main.dart", libraries))
        assertEquals("shop", appPackageOf("org-dartlang-app:///main.dart", libraries))
        // Only a library with the same file name counts.
        assertEquals("main_dev", appPackageOf("org-dartlang-app:///main_dev.dart", libraries))
    }

    @Test
    fun `falls back to the file stem, or null`() {
        assertEquals("server", appPackageOf("file:///tmp/server.dart"))
        assertNull(appPackageOf(null))
        assertNull(appPackageOf(""))
    }
}

package com.manishdevan.flutterdb.service

import com.intellij.util.xmlb.XmlSerializer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SavedQueryStoreTest {
    @Test
    fun `saving the same name again (ignoring case) updates the query and keeps its id`() {
        val s = SavedQueryStore()
        var changes = 0
        s.addListener { changes++ }
        val first = s.save("shop", " Top users ", " SELECT 1 ", "sqlite", now = 10)
        assertEquals("Top users", first.name)
        assertEquals("SELECT 1", first.sql)
        assertEquals(10, first.createdAt)
        assertNull(first.updatedAt)

        val second = s.save("shop", "top USERS", "SELECT 2", now = 20)
        assertEquals(first.id, second.id)
        assertEquals("top USERS", second.name)
        assertEquals("SELECT 2", second.sql)
        assertEquals("sqlite", second.databaseType)
        assertEquals(10, second.createdAt)
        assertEquals(20L, second.updatedAt)
        assertEquals(listOf(second), s.saved("shop"))
        assertEquals(2, changes)
    }

    @Test
    fun `queries are kept per app, sorted by name`() {
        val s = SavedQueryStore()
        s.save("shop", "zeta", "SELECT z")
        s.save("shop", "Alpha", "SELECT a")
        s.save("crm", "alpha", "SELECT c")
        assertEquals(listOf("Alpha", "zeta"), s.saved("shop").map { it.name })
        assertEquals(listOf("SELECT c"), s.saved("crm").map { it.sql })
        assertTrue(s.saved("other").isEmpty())
        // Returned queries are copies.
        s.saved("shop").first().sql = "changed"
        assertEquals("SELECT a", s.saved("shop").first().sql)
    }

    @Test
    fun `delete removes one query and drops empty apps`() {
        val s = SavedQueryStore()
        val a = s.save("shop", "a", "SELECT a")
        val b = s.save("shop", "b", "SELECT b")
        s.deleteSaved("crm", a.id) // another app: nothing happens
        s.deleteSaved("shop", a.id)
        assertEquals(listOf(b.id), s.saved("shop").map { it.id })
        s.deleteSaved("shop", b.id)
        assertTrue(s.state.apps.isEmpty())
    }

    @Test
    fun `groups list the current app first, then by name`() {
        val s = SavedQueryStore()
        s.save("zoo", "q", "SELECT 1")
        s.save("Beta", "q", "SELECT 1")
        s.save("alpha", "q", "SELECT 1")
        assertEquals(listOf("alpha", "Beta", "zoo"), s.savedGroups().map { it.app })
        assertEquals(listOf("zoo", "alpha", "Beta"), s.savedGroups("zoo").map { it.app })
        assertEquals(listOf("alpha", "Beta", "zoo"), s.savedGroups("unknown").map { it.app })
    }

    @Test
    fun `legacy queries move to an app without replacing its own`() {
        val s = SavedQueryStore()
        s.save("shop", "Users", "SELECT mine")
        s.adoptLegacySaved(
            "shop",
            listOf(SavedQuery("l1", "users", "SELECT old", null, 1), SavedQuery("l2", "Orders", "SELECT o", "sqlite", 2)),
        )
        assertEquals(listOf("Orders" to "SELECT o", "Users" to "SELECT mine"), s.saved("shop").map { it.name to it.sql })
        assertEquals("l2", s.saved("shop").first().id)
        s.adoptLegacySaved("crm", emptyList())
        assertTrue(s.saved("crm").isEmpty())
    }

    @Test
    fun `state survives xml serialization`() {
        val s = SavedQueryStore()
        s.save("shop", "a", "SELECT a", "sqlite", now = 5)
        s.save("shop", "a", "SELECT b", now = 6)
        s.save("crm", "c", "SELECT c")
        val xml = XmlSerializer.serialize(s.state)
        val restored = SavedQueryStore()
        restored.loadState(XmlSerializer.deserialize(xml, SavedQueryStoreState::class.java))
        assertEquals(s.savedGroups("shop"), restored.savedGroups("shop"))
        assertEquals(6L, restored.saved("shop").single().updatedAt)
    }
}

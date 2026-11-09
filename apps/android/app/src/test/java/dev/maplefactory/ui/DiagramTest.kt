package dev.maplefactory.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DiagramTest {
    @Test
    fun renderScriptEscapesTheSourceAsJson() {
        val script = diagramRenderScript("flowchart LR\n  a[\"quote\"] --> b</script>", viewer = true, dark = false)
        assertEquals(
            "window.mapleDiagram && window.mapleDiagram.render({\"source\":\"flowchart LR\\n  a[\\\"quote\\\"] --> b<\\/script>\",\"mode\":\"viewer\",\"theme\":\"light\"});",
            script,
        )
        assertTrue(diagramRenderScript("graph TD", viewer = false, dark = true).contains("\"mode\":\"inline\",\"theme\":\"dark\""))
    }

    @Test
    fun onlyTheBundledViewerLoads() {
        assertTrue(isBundledDiagramUrl(DIAGRAM_PAGE))
        assertTrue(isBundledDiagramUrl("file:///android_asset/mermaid/mermaid.min.js"))
        assertFalse(isBundledDiagramUrl("https://example.com/x.png"))
        assertFalse(isBundledDiagramUrl("file:///android_asset/mermaid/../secrets"))
        assertFalse(isBundledDiagramUrl("file:///data/data/dev.maplefactory/shared_prefs/x.xml"))
    }
}

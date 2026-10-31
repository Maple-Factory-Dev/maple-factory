package dev.maplefactory.kit

import org.junit.Assert.assertEquals
import org.junit.Test

class DiffTest {
    @Test fun parsesFilesAndHunks() {
        val files = DiffFile.parse(
            """
            diff --git a/a.ts b/a.ts
            new file mode 100644
            --- /dev/null
            +++ b/a.ts
            @@ -0,0 +1,2 @@
            +one
            +two
            diff --git a/b.ts b/b.ts
            --- a/b.ts
            +++ b/b.ts
            @@ -40,3 +40,3 @@ export function f() {
             keep
            -old
            +new
            """.trimIndent(),
        )
        assertEquals(listOf("a.ts", "b.ts"), files.map { it.path })
        assertEquals(2, files[0].added)
        assertEquals(1 to 1, files[1].added to files[1].removed)
        val lines = files[1].hunks.single().lines
        assertEquals(listOf(DiffLine.Kind.Context, DiffLine.Kind.Removed, DiffLine.Kind.Added), lines.map { it.kind })
        assertEquals(41, lines[1].old)
        assertEquals(41, lines[2].new)
        assertEquals("@@ -40,2 +40,2 @@ export function f() {", files[1].hunks.single().header)
    }
}

package dev.maplefactory.kit

// A unified diff, as the factory serves a task's (`GET /api/tasks/<id>/diff`), parsed into files and hunks.
// MapleKit's Diff.swift, for Android.

data class DiffLine(val kind: Kind, val text: String, val old: Int?, val new: Int?) {
    enum class Kind { Context, Added, Removed }
}

data class DiffHunk(val header: String, val lines: List<DiffLine>) {
    companion object {
        /** Builds a hunk from its lines, each prefixed with " ", "+" or "-", counting each side's lines as it goes. */
        fun of(oldStart: Int, newStart: Int, context: String, raws: List<String>): DiffHunk {
            var old = oldStart
            var new = newStart
            val parsed = raws.map { raw ->
                val text = raw.drop(1)
                when (raw.firstOrNull() ?: ' ') {
                    '+' -> DiffLine(DiffLine.Kind.Added, text, null, new).also { new++ }
                    '-' -> DiffLine(DiffLine.Kind.Removed, text, old, null).also { old++ }
                    else -> DiffLine(DiffLine.Kind.Context, text, old, new).also { old++; new++ }
                }
            }
            return DiffHunk("@@ -$oldStart,${old - oldStart} +$newStart,${new - newStart} @@ $context", parsed)
        }
    }
}

data class DiffFile(val path: String, val added: Int, val removed: Int, val hunks: List<DiffHunk> = emptyList()) {
    companion object {
        /** The files in a unified diff (`git diff` output), with their hunks. */
        fun parse(patch: String): List<DiffFile> {
            val files = mutableListOf<DiffFile>()
            var path: String? = null
            var added = 0
            var removed = 0
            val hunks = mutableListOf<DiffHunk>()
            var hunk: Triple<Pair<Int, Int>, String, MutableList<String>>? = null

            fun closeHunk() {
                hunk?.let { (starts, context, lines) -> hunks += DiffHunk.of(starts.first, starts.second, context, lines) }
                hunk = null
            }
            fun closeFile() {
                closeHunk()
                path?.let { files += DiffFile(it, added, removed, hunks.toList()) }
                path = null
                added = 0
                removed = 0
                hunks.clear()
            }

            for (line in patch.split("\n")) {
                if (line.startsWith("diff --git ")) {
                    closeFile()
                    // "diff --git a/x b/x": the b side, until +++ says better.
                    path = line.split(" b/").last()
                } else if (hunk == null && line.startsWith("+++ ")) {
                    if (line != "+++ /dev/null") path = line.drop(4).removePrefix("b/")
                } else if (hunk == null && (line.startsWith("--- ") || line.startsWith("index ") || line.startsWith("new file") ||
                        line.startsWith("deleted file") || line.startsWith("Binary files"))
                ) {
                    continue
                } else if (line.startsWith("@@")) {
                    closeHunk()
                    // @@ -12,7 +12,9 @@ context
                    val parts = line.split(" ", limit = 5)
                    fun start(s: String) = s.drop(1).split(",").first().toIntOrNull() ?: 1
                    val context = line.split("@@").drop(2).joinToString("@@").trim()
                    hunk = Triple(
                        Pair(if (parts.size > 1) start(parts[1]) else 1, if (parts.size > 2) start(parts[2]) else 1),
                        context,
                        mutableListOf(),
                    )
                } else if (hunk != null && line.isNotEmpty() && line[0] in "+- ") {
                    if (line[0] == '+') added++ else if (line[0] == '-') removed++
                    hunk!!.third += line
                }
            }
            closeFile()
            return files
        }
    }
}

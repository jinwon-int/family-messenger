// file-v2 공유 벡터(#366 3d) — host-core `file_v2`(봇·ios-ffi `fileV2Check`/`fileV2Classify`)·웹 `file-v2.js` 와 같은 파일
// `archive/native-mls/tests/fixtures/file-v2-vectors.json` 을 이 앱의 [FileV2] 로 돌린다. `lenient` 에 "kotlin" 이 있는 항목은
// 이 구현이 받아들이는 알려진 차이(짝 없는 서로게이트 이름 — 송신자는 만들지 않는다)라 받아야 한다.
// android.* 없이 JVM 에서 돈다(CI `:app:testDebugUnitTest`). JSON 읽개는 AgentChoicesTest 의 [MiniJson].
package com.seoyoon_family.hande.core

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue
import kotlin.test.fail

class FileV2VectorsTest {
    private val fixture: Map<*, *> by lazy {
        var dir: File? = File(".").absoluteFile
        while (dir != null) {
            val f = File(dir, "archive/native-mls/tests/fixtures/file-v2-vectors.json")
            if (f.isFile) return@lazy MiniJson(f.readText(Charsets.UTF_8)).parse() as Map<*, *>
            dir = dir.parentFile
        }
        fail("file-v2-vectors.json not found above ${File(".").absolutePath}")
    }

    private fun unhex(h: String) = ByteArray(h.length / 2) { h.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

    private fun bytesOf(c: Map<*, *>): ByteArray = (c["hex"] as String?)?.let { unhex(it) } ?: (c["text"] as String).toByteArray(Charsets.UTF_8)

    @Test fun descriptorVectors() {
        val cases = fixture["descriptors"] as List<*>
        assertTrue(cases.size >= 50, "벡터가 비어 있지 않다")
        for (c in cases) {
            c as Map<*, *>
            val name = c["name"] as String
            val lenient = (c["lenient"] as List<*>?).orEmpty().contains("kotlin")
            if (c["expect"] == "accept" || lenient) {
                val d = FileV2.parseDescriptor(bytesOf(c))
                if (c["expect"] == "accept") assertEquals(c["size"] as Long, d.size, name)
                continue
            }
            val reason = assertFailsWith<FileV2.Rejected>(name) { FileV2.parseDescriptor(bytesOf(c)) }.reason
            (c["reason"] as String?)?.let { assertEquals(it, reason, name) }
        }
    }

    @Test fun classifyVectors() {
        for (c in fixture["classify"] as List<*>) {
            c as Map<*, *>
            val name = c["name"] as String
            val row = FileV2.classify(c["client_id"] as String, (c["plaintext"] as String).toByteArray(Charsets.UTF_8))
            // null = 저장하지 않음(status) · v1 첨부 행 kind 는 "attachment".
            val kind = when (val k = row?.kind ?: "status") {
                MessageSchema.KIND_ATTACHMENT -> "file-v1"
                else -> k
            }
            assertEquals(c["kind"] as String, kind, name)
        }
    }
}

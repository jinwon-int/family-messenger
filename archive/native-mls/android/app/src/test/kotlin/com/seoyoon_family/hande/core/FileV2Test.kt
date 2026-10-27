// file-v2 설명자 검증·수신 분류 고정(#499, FILE-V2.md). 웹 `file-v2.js parseDescriptor` 와 같은 판정 — 다른 점은 중복 키 거부 하나.
// android.* 없이 JVM 에서 돈다(CI `:app:testDebugUnitTest`).
package com.seoyoon_family.hande.core

import com.seoyoon_family.hande.ui.Strings
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class FileV2Test {
    private val key = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8" // bytes 0..31
    private val nonce = "AAECAwQFBgcICQoL" // bytes 0..11
    private val blob = "2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881"
    private val client = "file-v2-0f8fad5b-d9cb-469f-a165-70867728950e"
    private val minimal = """{"v":2,"blob":"$blob","size":2481920,"key":"$key","nonce":"$nonce"}"""

    private fun desc(fields: String) = """{"v":2,"blob":"$blob","size":10,"key":"$key","nonce":"$nonce"$fields}"""
    private fun parse(json: String) = FileV2.parseDescriptor(json.toByteArray(Charsets.UTF_8))
    private fun rejected(json: String): String = assertFailsWith<FileV2.Rejected>(json) { parse(json) }.reason

    @Test fun minimalDescriptor() {
        val d = parse(minimal)
        assertEquals(blob, d.blob)
        assertEquals(2481920L, d.size)
        assertContentEquals(ByteArray(32) { it.toByte() }, d.key)
        assertContentEquals(ByteArray(12) { it.toByte() }, d.nonce)
        assertNull(d.mime); assertNull(d.name); assertNull(d.w); assertNull(d.h)
        assertFalse(d.toString().contains(key), "toString must not leak the key")
    }

    @Test fun optionalFieldsAndWhitespace() {
        val d = parse(" \n" + desc(""","mime":"image/jpeg","name":"사진 📷.jpg","w":4032,"h":3024""") + "\r\n\t")
        assertEquals("image/jpeg", d.mime)
        assertEquals("사진 📷.jpg", d.name)
        assertEquals(4032L, d.w); assertEquals(3024L, d.h)
        // JSON 이스케이프와 정수 표기(JS 와 같이 2.0 · 1e1 도 정수)
        assertEquals("a/b", parse(desc(""","name":"a\/b"""")).name)
        assertEquals("가", parse(desc(""","name":"가"""")).name)
        assertEquals(10L, parse("""{"v":2.0,"blob":"$blob","size":1e1,"key":"$key","nonce":"$nonce"}""").size)
    }

    @Test fun limits() {
        assertEquals(FileV2.MAX_FILE_BYTES, parse(minimal.replace("2481920", "52428800")).size)
        assertEquals("size", rejected(minimal.replace("2481920", "52428801")))
        assertEquals("size", rejected(minimal.replace("2481920", "0")))
        assertEquals("size", rejected(minimal.replace("2481920", "1.5")))
        assertEquals("size", rejected(minimal.replace("2481920", "-1")))
        assertEquals("size", rejected(minimal.replace("2481920", "\"10\"")))
        assertEquals("size", rejected(minimal.replace("2481920", "1e400")))
        assertEquals(20000L, parse(desc(""","w":20000""")).w)
        assertEquals("w", rejected(desc(""","w":20001""")))
        assertEquals("h", rejected(desc(""","h":0""")))
        assertEquals("name", parse(desc(""","name":"${"가".repeat(255)}"""")).name?.let { "name" })
        assertEquals("name", rejected(desc(""","name":"${"가".repeat(256)}"""")))
        assertEquals("name", parse(desc(""","name":"${"📷".repeat(255)}"""")).name?.let { "name" }) // 코드 포인트로 센다
        assertEquals("a/${"b".repeat(64)}", parse(desc(""","mime":"a/${"b".repeat(64)}"""")).mime)
        assertEquals("mime", rejected(desc(""","mime":"a/${"b".repeat(65)}"""")))
    }

    @Test fun shapeRejections() {
        assertEquals("unknown key", rejected(desc(""","extra":1""")))
        assertEquals("unknown key", rejected(desc(""","__proto__":{}""")))
        assertEquals("missing nonce", rejected("""{"v":2,"blob":"$blob","size":10,"key":"$key"}"""))
        assertEquals("version", rejected(minimal.replace("\"v\":2", "\"v\":3")))
        assertEquals("version", rejected(minimal.replace("\"v\":2", "\"v\":\"2\"")))
        assertEquals("blob", rejected(minimal.replace(blob, blob.uppercase())))
        assertEquals("blob", rejected(minimal.replace(blob, blob.drop(1))))
        assertEquals("not an object", rejected("[1,2]"))
        assertEquals("not an object", rejected("null"))
        assertEquals("mime", rejected(desc(""","mime":"image/jpeg\n"""")))
        assertEquals("mime", rejected(desc(""","mime":"jpeg"""")))
        assertEquals("name", rejected(desc(""","name":""""")))
        assertEquals("name", rejected(desc(""","name":"a\u0007b"""")))
        assertEquals("name", rejected(desc(""","name":"a\u0085b"""")))
        assertEquals("name", rejected(desc(""","name":7""")))
    }

    @Test fun keyAndNonceMustBeCanonicalBase64url() {
        assertEquals("key", rejected(minimal.replace(key, key.dropLast(1) + "9"))) // 끝 비트가 0 이 아님
        assertEquals("key", rejected(minimal.replace(key, "$key=")))
        assertEquals("key", rejected(minimal.replace(key, key.replace('_', '/').replace("A", "+"))))
        assertEquals("key", rejected(minimal.replace(key, key.drop(4)))) // 29 B
        // nonce 는 key 의 앞부분과 같은 문자열이라 필드째 바꾼다
        assertEquals("nonce", rejected(minimal.replace("\"nonce\":\"$nonce\"", "\"nonce\":\"${nonce}AAAA\"")))
        assertEquals("nonce", rejected(minimal.replace("\"nonce\":\"$nonce\"", "\"nonce\":\"\"")))
        assertNull(FileV2.base64urlDecode("A"))
        assertContentEquals(byteArrayOf(-1), FileV2.base64urlDecode("_w"))
    }

    @Test fun strictJson() {
        assertEquals("not json", rejected("$minimal x"))
        assertEquals("not json", rejected(minimal.dropLast(1) + ",}"))
        assertEquals("not json", rejected(minimal.replace("\"v\":2", "v:2")))
        assertEquals("not json", rejected(minimal.replace("\"v\":2", "'v':2")))
        assertEquals("not json", rejected(minimal.replace("\"v\":2", "\"v\":02")))
        assertEquals("not json", rejected(minimal.replace("\"v\":2", "\"v\":NaN")))
        assertEquals("not json", rejected(desc(""","name":"a${'\t'}b"""")))   // 이스케이프 안 한 제어 문자
        assertEquals("not json", rejected(desc(""","name":"\x"""")))
        assertEquals("not json", rejected(minimal + "\n// c"))
        assertEquals("not json", rejected("﻿$minimal"))
        assertEquals("not json", rejected(""))
        assertEquals("not json", rejected("[".repeat(40) + "]".repeat(40)))
        // 중복 키는 거부(웹 JSON.parse 는 뒤 값 — 클라이언트마다 다른 blob 을 보지 않게 닫는다)
        assertEquals("not json", rejected(minimal.dropLast(1) + ""","size":11}"""))
    }

    @Test fun byteLevelRejections() {
        val big = desc(""","name":"${"a".repeat(200)}"""").padEnd(FileV2.MAX_DESCRIPTOR_BYTES + 1, ' ')
        assertEquals("too large", rejected(big))
        assertEquals("not utf-8", assertFailsWith<FileV2.Rejected> { FileV2.parseDescriptor(byteArrayOf(0x7b, 0xc3.toByte(), 0x28, 0x7d)) }.reason)
        assertEquals(10L, parse(desc("").padEnd(FileV2.MAX_DESCRIPTOR_BYTES, ' ')).size) // 정확히 4096 B 는 허용
    }

    @Test fun clientIdShape() {
        assertTrue(FileV2.isClientId(client))
        assertFalse(FileV2.isClientId(client.uppercase()))
        assertFalse(FileV2.isClientId("$client-x"))
        assertFalse(FileV2.isClientId("file-v1-0f8fad5b-d9cb-469f-a165-70867728950e"))
    }

    // ---- 수신 분류: file-v2 평문(키)은 어떤 경우에도 글로 저장되지 않는다 ----

    @Test fun classifyValidFileV2StoresDescriptorNotText() {
        val bytes = minimal.toByteArray()
        val row = FileV2.classify(client, bytes)
        assertEquals(MessageSchema.KIND_FILE_V2, row.kind)
        assertEquals(Strings.attachmentPlaceholder(2481920), row.body)
        assertFalse(row.body.contains(key))
        assertContentEquals(bytes, row.attachment)
    }

    @Test fun classifyInvalidFileV2IsUndecryptableAndDropsPlaintext() {
        for ((id, text) in listOf(
            client to minimal.replace("\"v\":2", "\"v\":3"),
            client to "hello $key",
            "file-v2-not-a-uuid" to minimal, // 접두는 맞지만 정규형이 아님 — 글로 열지 않는다
        )) {
            val row = FileV2.classify(id, text.toByteArray())
            assertEquals(MessageSchema.KIND_UNDECRYPTABLE, row.kind, id)
            assertEquals(Strings.fileV2Invalid, row.body)
            assertNull(row.attachment)
        }
    }

    @Test fun classifyV1AndTextUnchanged() {
        val file = byteArrayOf(1, 2, 3)
        val v1 = FileV2.classify("file-v1-0f8fad5b-d9cb-469f-a165-70867728950e", file)
        assertEquals(MessageSchema.KIND_ATTACHMENT, v1.kind)
        assertEquals("📎 첨부(3 B)", v1.body)
        assertContentEquals(file, v1.attachment)
        val text = FileV2.classify("c-123", "안녕".toByteArray())
        assertEquals(MessageSchema.KIND_TEXT, text.kind)
        assertEquals("안녕", text.body)
        assertNull(text.attachment)
    }
}

package com.moshinop.autofill_service

import java.util.Locale
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * Standard RFC 6238 / RFC 4226 compliant TOTP generator.
 * Respects secret, algorithm (SHA1, SHA256, SHA512), period (default 30s),
 * and digits (default 6).
 */
object KeyNestTotp {

    private const val DEFAULT_ALGORITHM = "SHA1"
    private const val DEFAULT_PERIOD = 30
    private const val DEFAULT_DIGITS = 6

    /**
     * Decodes an RFC 4648 Base32 string into raw bytes.
     * Tolerates spaces, hyphens, and missing padding.
     * Rejects URI strings (otpauth://) and invalid characters fail-closed.
     */
    fun decodeBase32(input: String?): ByteArray {
        if (input.isNullOrBlank()) return ByteArray(0)
        if (input.contains("://") || input.startsWith("otpauth", ignoreCase = true)) {
            // Kotlin computes strictly from normalized secrets and never parses otpauth://
            return ByteArray(0)
        }
        val clean = input.trim().uppercase(Locale.ROOT)
            .replace(Regex("[\\s\\-_]"), "")
            .replace(Regex("[=]+$"), "")
        if (clean.isEmpty() || clean.any { it !in 'A'..'Z' && it !in '2'..'7' }) {
            return ByteArray(0)
        }

        val out = ArrayList<Byte>()
        var buffer = 0
        var bitsLeft = 0
        for (c in clean) {
            val v = if (c in 'A'..'Z') {
                c - 'A'
            } else if (c in '2'..'7') {
                c - '2' + 26
            } else {
                return ByteArray(0)
            }
            buffer = (buffer shl 5) or (v and 0x1F)
            bitsLeft += 5
            if (bitsLeft >= 8) {
                out.add(((buffer shr (bitsLeft - 8)) and 0xFF).toByte())
                bitsLeft -= 8
            }
        }
        return out.toByteArray()
    }

    /**
     * Calculates remaining seconds in the current TOTP step window.
     */
    fun getRemainingSeconds(period: Int = DEFAULT_PERIOD, timestampMs: Long = System.currentTimeMillis()): Int {
        val step = if (period > 0) period else DEFAULT_PERIOD
        val elapsed = ((timestampMs / 1000L) % step).toInt()
        return (step - elapsed).coerceAtLeast(1)
    }

    /**
     * Generates a live TOTP code for the given Base32 secret.
     */
    fun generateTotp(
        secretBase32: String?,
        algorithm: String = DEFAULT_ALGORITHM,
        period: Int = DEFAULT_PERIOD,
        digits: Int = DEFAULT_DIGITS,
        timestampMs: Long = System.currentTimeMillis()
    ): String {
        if (secretBase32.isNullOrBlank()) return ""

        val keyBytes = decodeBase32(secretBase32)
        if (keyBytes.isEmpty()) return ""

        val step = if (period > 0) period else DEFAULT_PERIOD
        val numDigits = if (digits in 4..10) digits else DEFAULT_DIGITS
        val counter = (timestampMs / 1000L) / step

        val hmacAlgorithm = when (algorithm.trim().uppercase(Locale.ROOT).replace("-", "")) {
            "SHA256" -> "HmacSHA256"
            "SHA512" -> "HmacSHA512"
            else -> "HmacSHA1"
        }

        try {
            val msg = ByteArray(8)
            var t = counter
            for (i in 7 downTo 0) {
                msg[i] = (t and 0xFF).toByte()
                t = t shr 8
            }

            val mac = Mac.getInstance(hmacAlgorithm)
            val key = SecretKeySpec(keyBytes, hmacAlgorithm)
            mac.init(key)
            val hash = mac.doFinal(msg)

            val offset = hash[hash.size - 1].toInt() and 0x0F
            val binary = ((hash[offset].toInt() and 0x7F) shl 24) or
                    ((hash[offset + 1].toInt() and 0xFF) shl 16) or
                    ((hash[offset + 2].toInt() and 0xFF) shl 8) or
                    (hash[offset + 3].toInt() and 0xFF)

            var mod = 1L
            for (i in 0 until numDigits) {
                mod *= 10L
            }
            val otp = binary % mod
            return String.format(Locale.ROOT, "%0${numDigits}d", otp)
        } catch (e: Exception) {
            return ""
        }
    }

    /**
     * Formats a TOTP code with a space in the middle for improved readability.
     * E.g. "123456" -> "123 456"
     */
    fun formatDisplayCode(code: String): String {
        if (code.length == 6) {
            return "${code.substring(0, 3)} ${code.substring(3)}"
        } else if (code.length == 8) {
            return "${code.substring(0, 4)} ${code.substring(4)}"
        }
        return code
    }
}

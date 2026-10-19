package com.moshinop.autofill_service

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.annotation.RequiresApi
import mu.KotlinLogging
import java.security.KeyStore
import java.security.SecureRandom
import java.security.Security
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

@RequiresApi(Build.VERSION_CODES.M)
object AutofillSecurityHelper {
    private val logger = KotlinLogging.logger {}

    const val ALIAS_PENDING_SAVE = "keynest_pending_save_v1"
    const val ALIAS_METADATA_CACHE = "keynest_autofill_meta_v1"

    private const val ANDROID_KEYSTORE = "AndroidKeyStore"
    private const val TRANSFORMATION = "AES/GCM/NoPadding"
    private const val GCM_TAG_LENGTH_BITS = 128
    private const val IV_LENGTH_BYTES = 12 // 96-bit IV recommended for AES-GCM

    private val secureRandom = SecureRandom()

    // In-memory fallback keys strictly for non-Android JVM unit tests where AndroidKeyStore provider is absent
    private val testFallbackKeys = mutableMapOf<String, SecretKey>()

    private fun isAndroidKeyStoreAvailable(): Boolean {
        return try {
            Security.getProvider(ANDROID_KEYSTORE) != null
        } catch (_: Exception) {
            false
        }
    }

    private fun encodeBase64(bytes: ByteArray): String {
        return try {
            Base64.encodeToString(bytes, Base64.NO_WRAP)
        } catch (_: UnsatisfiedLinkError) {
            java.util.Base64.getEncoder().encodeToString(bytes)
        } catch (_: RuntimeException) {
            java.util.Base64.getEncoder().encodeToString(bytes)
        }
    }

    private fun decodeBase64(str: String): ByteArray {
        return try {
            Base64.decode(str, Base64.NO_WRAP)
        } catch (_: UnsatisfiedLinkError) {
            java.util.Base64.getDecoder().decode(str)
        } catch (_: RuntimeException) {
            java.util.Base64.getDecoder().decode(str)
        }
    }

    @Synchronized
    fun getOrCreateSecretKey(alias: String): SecretKey {
        if (!isAndroidKeyStoreAvailable()) {
            return testFallbackKeys.getOrPut(alias) {
                val keyGen = KeyGenerator.getInstance("AES")
                keyGen.init(256)
                keyGen.generateKey()
            }
        }

        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        try {
            if (keyStore.containsAlias(alias)) {
                val entry = keyStore.getEntry(alias, null) as? KeyStore.SecretKeyEntry
                if (entry != null) {
                    return entry.secretKey
                }
            }
        } catch (e: Exception) {
            logger.warn { "Error accessing Keystore key for alias $alias, regenerating: ${e.message}" }
            try {
                keyStore.deleteEntry(alias)
            } catch (_: Exception) {}
        }

        val keyGenerator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        val spec = KeyGenParameterSpec.Builder(
            alias,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setRandomizedEncryptionRequired(false) // Allows passing our own fresh 96-bit IV
            .build()
        keyGenerator.init(spec)
        return keyGenerator.generateKey()
    }

    /**
     * Encrypts plaintext using AES-256-GCM backed by Android Keystore.
     * Generates a fresh cryptographically secure 96-bit IV for every encryption.
     * Returns Base64-encoded payload containing [IV (12 bytes) + Ciphertext + GCM Tag (16 bytes)],
     * or null if encryption fails.
     */
    fun encrypt(alias: String, plaintext: String): String? {
        if (plaintext.isEmpty()) return ""
        return try {
            val secretKey = getOrCreateSecretKey(alias)
            val iv = ByteArray(IV_LENGTH_BYTES).apply { secureRandom.nextBytes(this) }
            val cipher = Cipher.getInstance(TRANSFORMATION)
            try {
                cipher.init(Cipher.ENCRYPT_MODE, secretKey, GCMParameterSpec(GCM_TAG_LENGTH_BITS, iv))
            } catch (e: java.security.InvalidAlgorithmParameterException) {
                // In case Keystore provider enforces internal IV generation
                cipher.init(Cipher.ENCRYPT_MODE, secretKey)
            }
            val actualIv = cipher.iv ?: iv
            val ciphertext = cipher.doFinal(plaintext.toByteArray(Charsets.UTF_8))
            val combined = ByteArray(actualIv.size + ciphertext.size)
            System.arraycopy(actualIv, 0, combined, 0, actualIv.size)
            System.arraycopy(ciphertext, 0, combined, actualIv.size, ciphertext.size)
            encodeBase64(combined)
        } catch (e: Exception) {
            logger.warn { "Encryption failed for alias $alias: ${e.message}" }
            null
        }
    }

    /**
     * Decrypts Base64-encoded AES-256-GCM ciphertext using the key for [alias].
     * Returns the decrypted UTF-8 string, or null if decryption fails (e.g. corrupted ciphertext,
     * authentication tag mismatch, or missing/invalid key).
     */
    fun decrypt(alias: String, base64Ciphertext: String?): String? {
        if (base64Ciphertext.isNullOrEmpty()) return null
        return try {
            val secretKey = if (isAndroidKeyStoreAvailable()) {
                val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
                if (!keyStore.containsAlias(alias)) {
                    logger.warn { "Key alias $alias not found in Keystore" }
                    return null
                }
                val entry = keyStore.getEntry(alias, null) as? KeyStore.SecretKeyEntry ?: return null
                entry.secretKey
            } else {
                testFallbackKeys[alias] ?: return null
            }

            val combined = decodeBase64(base64Ciphertext)
            if (combined.size < IV_LENGTH_BYTES + (GCM_TAG_LENGTH_BITS / 8)) {
                logger.warn { "Ciphertext payload too short for alias $alias" }
                return null
            }

            val iv = ByteArray(IV_LENGTH_BYTES)
            System.arraycopy(combined, 0, iv, 0, IV_LENGTH_BYTES)
            val ciphertext = ByteArray(combined.size - IV_LENGTH_BYTES)
            System.arraycopy(combined, IV_LENGTH_BYTES, ciphertext, 0, ciphertext.size)

            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, secretKey, GCMParameterSpec(GCM_TAG_LENGTH_BITS, iv))
            val plaintextBytes = cipher.doFinal(ciphertext)
            String(plaintextBytes, Charsets.UTF_8)
        } catch (e: Exception) {
            logger.warn { "Decryption failed for alias $alias: ${e.message}" }
            null
        }
    }

    /**
     * Safely deletes the key for [alias] if present.
     */
    fun deleteKey(alias: String) {
        try {
            if (isAndroidKeyStoreAvailable()) {
                val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
                if (keyStore.containsAlias(alias)) {
                    keyStore.deleteEntry(alias)
                }
            } else {
                testFallbackKeys.remove(alias)
            }
        } catch (e: Exception) {
            logger.warn { "Failed to delete key alias $alias: ${e.message}" }
        }
    }
}

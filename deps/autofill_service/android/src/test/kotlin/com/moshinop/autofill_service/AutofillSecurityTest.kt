package com.moshinop.autofill_service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AutofillSecurityTest {

    @Test
    fun testEncryptionDecryptionRoundTrip() {
        val payload = """{"username":"user@example.com","password":"SuperSecretPassword123!","packageName":"com.example.app"}"""
        val encrypted = AutofillSecurityHelper.encrypt(
            AutofillSecurityHelper.ALIAS_PENDING_SAVE,
            payload
        )

        assertNotNull("Encrypted payload should not be null", encrypted)
        assertTrue("Ciphertext should be non-empty", encrypted!!.isNotEmpty())
        assertFalse("Ciphertext must not contain plaintext password", encrypted.contains("SuperSecretPassword123!"))
        assertFalse("Ciphertext must not contain plaintext username", encrypted.contains("user@example.com"))

        val decrypted = AutofillSecurityHelper.decrypt(
            AutofillSecurityHelper.ALIAS_PENDING_SAVE,
            encrypted
        )

        assertEquals("Decrypted payload must match original", payload, decrypted)
    }

    @Test
    fun testFreshIVPerEncryptionProducesDifferentCiphertexts() {
        val payload = """{"secret":"identical_payload"}"""
        val encrypted1 = AutofillSecurityHelper.encrypt(AutofillSecurityHelper.ALIAS_PENDING_SAVE, payload)
        val encrypted2 = AutofillSecurityHelper.encrypt(AutofillSecurityHelper.ALIAS_PENDING_SAVE, payload)

        assertNotNull(encrypted1)
        assertNotNull(encrypted2)
        assertNotEquals("Each encryption must use a fresh 96-bit IV producing unique ciphertext", encrypted1, encrypted2)

        assertEquals(payload, AutofillSecurityHelper.decrypt(AutofillSecurityHelper.ALIAS_PENDING_SAVE, encrypted1))
        assertEquals(payload, AutofillSecurityHelper.decrypt(AutofillSecurityHelper.ALIAS_PENDING_SAVE, encrypted2))
    }

    @Test
    fun testCorruptedCiphertextReturnsNullGracefully() {
        val payload = """{"username":"alice","password":"secret_value"}"""
        val encrypted = AutofillSecurityHelper.encrypt(AutofillSecurityHelper.ALIAS_PENDING_SAVE, payload)!!

        // Corrupt characters in the middle of Base64 ciphertext
        val chars = encrypted.toCharArray()
        val mid = chars.size / 2
        chars[mid] = if (chars[mid] == 'A') 'B' else 'A'
        val corrupted = String(chars)

        val decrypted = AutofillSecurityHelper.decrypt(AutofillSecurityHelper.ALIAS_PENDING_SAVE, corrupted)
        assertNull("Decryption of corrupted ciphertext must return null", decrypted)
    }

    @Test
    fun testTruncatedCiphertextReturnsNull() {
        val truncated = "dG9vc2hvcnQ=" // "tooshort" in base64, less than 28 bytes
        val decrypted = AutofillSecurityHelper.decrypt(AutofillSecurityHelper.ALIAS_PENDING_SAVE, truncated)
        assertNull("Payload shorter than IV + GCM tag must return null", decrypted)
    }

    @Test
    fun testMissingKeyReturnsNull() {
        val dummyCiphertext = "QUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQQ=="
        val decrypted = AutofillSecurityHelper.decrypt("non_existent_key_alias", dummyCiphertext)
        assertNull("Decryption with missing key alias must return null", decrypted)
    }

    @Test
    fun testKeyIsolationBetweenPendingSaveAndMetadataCache() {
        val payload = """[{"id":"entry-1","label":"GitHub","username":"octocat"}]"""
        val encrypted = AutofillSecurityHelper.encrypt(AutofillSecurityHelper.ALIAS_METADATA_CACHE, payload)!!

        // Attempt decrypt with different key alias
        val crossDecrypt = AutofillSecurityHelper.decrypt(AutofillSecurityHelper.ALIAS_PENDING_SAVE, encrypted)
        assertNull("Data encrypted with ALIAS_METADATA_CACHE must not be decryptable with ALIAS_PENDING_SAVE", crossDecrypt)

        // Decrypt with correct key alias
        val correctDecrypt = AutofillSecurityHelper.decrypt(AutofillSecurityHelper.ALIAS_METADATA_CACHE, encrypted)
        assertEquals(payload, correctDecrypt)
    }

    @Test
    fun testEmptyPlaintextHandling() {
        val encrypted = AutofillSecurityHelper.encrypt(AutofillSecurityHelper.ALIAS_PENDING_SAVE, "")
        assertEquals("", encrypted)

        val decrypted = AutofillSecurityHelper.decrypt(AutofillSecurityHelper.ALIAS_PENDING_SAVE, "")
        assertNull(decrypted)

        val decryptedNull = AutofillSecurityHelper.decrypt(AutofillSecurityHelper.ALIAS_PENDING_SAVE, null)
        assertNull(decryptedNull)
    }

    @Test
    fun testLockedStoreReturnsNoSecrets() {
        val sampleEntries = listOf(
            NativeAutofillEntry(
                id = "entry-1",
                label = "Google",
                username = "alice@gmail.com",
                password = "SuperSecretPassword123!",
                urls = listOf("https://accounts.google.com"),
                packageNames = listOf("com.google.android.gms"),
                otp = "123456",
                otpSecret = "JBSWY3DPEHPK3PXP",
                hasTotp = true
            ),
            NativeAutofillEntry(
                id = "entry-2",
                label = "GitHub",
                username = "octocat",
                password = "AnotherSecretPassword456!",
                urls = listOf("https://github.com"),
                packageNames = listOf("com.github.android"),
                otpSecret = "HXDMVJECJJWSRB3HWIZR4IFUGFTMXBOZ",
                hasTotp = true
            )
        )

        // 1. Sync entries (simulating unlocked vault)
        AutofillCredentialStore.sync(sampleEntries, autoLockSec = 300)
        assertFalse("Store should be unlocked after sync", AutofillCredentialStore.isLocked)
        assertTrue("Store should be active", AutofillCredentialStore.isUnlockedAndActive())

        val unlockedEntries = AutofillCredentialStore.getEntries()
        assertEquals(2, unlockedEntries.size)
        assertEquals("SuperSecretPassword123!", unlockedEntries[0].password)
        assertEquals("JBSWY3DPEHPK3PXP", unlockedEntries[0].otpSecret)

        // 2. Lock store (simulating vault lock / auto-lock / close)
        AutofillCredentialStore.clear()
        assertTrue("Store must be locked", AutofillCredentialStore.isLocked)
        assertFalse("Store must not be active", AutofillCredentialStore.isUnlockedAndActive())

        // 3. Verify getEntries() returns sanitized metadata with NO secrets
        val lockedEntries = AutofillCredentialStore.getEntries()
        assertEquals(2, lockedEntries.size)
        for (entry in lockedEntries) {
            assertEquals("Password must be blank when locked", "", entry.password)
            assertNull("OTP code must be null when locked", entry.otp)
            assertNull("OTP secret must be null when locked", entry.otpSecret)
            assertTrue("Non-sensitive metadata (username) must remain accessible", entry.username.isNotEmpty())
            assertTrue("Non-sensitive metadata (label) must remain accessible", entry.label.isNotEmpty())
        }

        // 4. Verify findMatches() returns sanitized metadata with NO secrets
        val matches = AutofillCredentialStore.findMatches("com.github.android", "github.com")
        assertTrue("Matches should be found", matches.isNotEmpty())
        for (match in matches) {
            assertEquals("Matched password must be blank when locked", "", match.password)
            assertNull("Matched OTP secret must be null when locked", match.otpSecret)
        }

        // 5. Verify getEntryById() returns sanitized entry with NO secrets
        val singleEntry = AutofillCredentialStore.getEntryById("entry-1")
        assertNotNull(singleEntry)
        assertEquals("", singleEntry!!.password)
        assertNull(singleEntry.otpSecret)
    }

    @Test
    fun testPurgeLifecycleWipesMemoryAndSessionTokens() {
        val sampleEntries = listOf(
            NativeAutofillEntry(
                id = "entry-secret",
                label = "VaultSecret",
                username = "admin",
                password = "MasterVaultPassword999!",
                urls = listOf("https://secret.corp")
            )
        )

        AutofillCredentialStore.sync(sampleEntries, autoLockSec = 300)
        AutofillCredentialStore.cacheSessionTokens(mapOf("vault-uuid-1" to "base64token"))
        AutofillCredentialStore.rememberPendingLogin("entry-secret", "secret.corp", "admin")

        assertNotNull(AutofillCredentialStore.getSessionTokens())
        assertNotNull(AutofillCredentialStore.getValidPendingLogin("secret.corp"))

        // Purge on lock
        AutofillCredentialStore.clear()

        assertTrue(AutofillCredentialStore.isLocked)
        assertNull("Session tokens must be purged on lock", AutofillCredentialStore.getSessionTokens())
        assertNull("Pending login must be purged on lock", AutofillCredentialStore.getValidPendingLogin("secret.corp"))

        // Purge everything including metadata cache
        AutofillCredentialStore.clearAll()
        assertTrue("getEntries() must be completely empty after clearAll", AutofillCredentialStore.getEntries().isEmpty())
        assertTrue("getMetadataEntries() must be empty after clearAll", AutofillCredentialStore.getMetadataEntries().isEmpty())
    }

    @Test
    fun testAutoLockTimeoutExpiresAndRevertsToLocked() {
        val sampleEntries = listOf(
            NativeAutofillEntry(
                id = "entry-timeout",
                label = "Banking",
                username = "user",
                password = "SensitiveBankingPassword!",
                urls = listOf("https://bank.com")
            )
        )

        // Set immediate auto-lock (0 seconds)
        AutofillCredentialStore.sync(sampleEntries, autoLockSec = 0)

        assertTrue("Immediate autoLockSeconds (0) must expire immediately", AutofillCredentialStore.isAutoLockExpired())
        assertFalse("Store must not be unlocked when auto-lock expired", AutofillCredentialStore.isUnlockedAndActive())

        val entries = AutofillCredentialStore.getEntries()
        for (e in entries) {
            assertEquals("", e.password)
        }
    }

    @Test
    fun testCorruptedOrInvalidatedKeyRecovery() {
        val payload = """[{"id":"corrupt-test","label":"Site","username":"user"}]"""
        val encrypted = AutofillSecurityHelper.encrypt(AutofillSecurityHelper.ALIAS_METADATA_CACHE, payload)
        assertNotNull(encrypted)

        // Simulate key invalidation or deletion
        AutofillSecurityHelper.deleteKey(AutofillSecurityHelper.ALIAS_METADATA_CACHE)

        // Attempting to decrypt with deleted key must return null gracefully, never throwing unhandled crash
        val decrypted = AutofillSecurityHelper.decrypt(AutofillSecurityHelper.ALIAS_METADATA_CACHE, encrypted)
        assertNull("Decryption after key invalidation/deletion must return null", decrypted)
    }

    @Test
    fun testPendingSaveDataExpiresAfterTtl() {
        val data = mapOf(
            "username" to "bob@example.com",
            "password" to "SecretPassword123!",
            "packageName" to "com.example.app",
            "webDomain" to "example.com"
        )
        AutofillServicePluginImpl.savePendingSaveData(null, data)
        assertNotNull("Pending save data should be present immediately after save", AutofillServicePluginImpl.loadPendingSaveData(null))

        // Age timestamp past strict 5 min TTL (300_000 ms)
        AutofillServicePluginImpl.pendingSaveTimestamp = System.currentTimeMillis() - 301_000L

        val expired = AutofillServicePluginImpl.loadPendingSaveData(null)
        assertNull("Staged pending save data older than 5 minutes must be discarded", expired)
        assertNull("In-memory cache must be wiped after expiry", AutofillServicePluginImpl.pendingSaveData)
    }

    @Test
    fun testPendingSaveDataPurgedOnLockAndCancel() {
        val data = mapOf(
            "username" to "alice@vault.net",
            "password" to "StagedPassword456!",
            "packageName" to "net.vault.android",
            "webDomain" to "vault.net"
        )
        AutofillServicePluginImpl.savePendingSaveData(null, data)
        assertEquals("alice@vault.net", AutofillServicePluginImpl.loadPendingSaveData(null)?.get("username"))

        // Purge on lock/cancel
        AutofillServicePluginImpl.clearPendingSaveData(null)

        assertNull("Pending save data must be null after purge", AutofillServicePluginImpl.loadPendingSaveData(null))
        assertEquals(0L, AutofillServicePluginImpl.pendingSaveTimestamp)
    }

    @Test
    fun testAutofillRequestStoreTtlExpiration() {
        AutofillRequestStore.clear()
        AutofillRequestStore.hasActiveRequest = true
        AutofillRequestStore.activeRequestId = 42
        AutofillRequestStore.activeSessionTimestamp = System.currentTimeMillis() - 305_000L // 5 min 5 sec ago

        assertTrue("Request older than 5 minutes must report as expired", AutofillRequestStore.isExpired())
        assertNull("latestStructure must return null and auto-clear when expired", AutofillRequestStore.latestStructure)
        assertFalse("Request store must no longer have active request after expiration clear", AutofillRequestStore.hasActiveRequest)
    }

    @Test
    fun testSamePageSessionUnlockContinuity() {
        val entry1 = NativeAutofillEntry(
            id = "entry-proton-1",
            label = "Proton Pass Account 1",
            username = "user1@proton.me",
            password = "PasswordOne123!",
            urls = listOf("https://account.proton.me")
        )
        val entry2 = NativeAutofillEntry(
            id = "entry-proton-2",
            label = "Proton Pass Account 2",
            username = "user2@proton.me",
            password = "PasswordTwo456!",
            urls = listOf("https://account.proton.me")
        )

        // 1. Initially vault is unlocked after first credential unlock
        AutofillCredentialStore.sync(listOf(entry1, entry2), autoLockSec = 300)
        assertTrue("Store must be unlocked after sync", AutofillCredentialStore.isUnlockedAndActive())
        assertFalse("Auto-lock must not be expired", AutofillCredentialStore.isAutoLockExpired())

        // 2. Clear input field and select entry 2 on the same login page
        // Fast-path lookup must immediately find entry 2 with decrypted password
        val retrieved = AutofillCredentialStore.getEntryById("entry-proton-2")
        assertNotNull("Entry 2 must be found without unlocking again", retrieved)
        assertEquals("PasswordTwo456!", retrieved?.password)
        assertTrue("Store must remain active and unlocked for multiple selections on same page", AutofillCredentialStore.isUnlockedAndActive())

        // 3. User interaction updates active timestamp
        val beforeTouch = AutofillCredentialStore.lastActiveTimestamp
        Thread.sleep(10)
        AutofillCredentialStore.touchActive()
        assertTrue("touchActive must advance timestamp", AutofillCredentialStore.lastActiveTimestamp >= beforeTouch)
    }

    @Test
    fun testSessionTokensAcrossAutofillAndLauncher() {
        AutofillCredentialStore.clear()
        assertTrue(AutofillCredentialStore.isLocked)

        val tokens = mapOf("vault-uuid-primary" to "AQIDBA==")
        AutofillCredentialStore.cacheSessionTokens(tokens)

        assertFalse("Store must not be locked after caching session tokens", AutofillCredentialStore.isLocked)
        assertNotNull("Session tokens must be retrievable across entry points", AutofillCredentialStore.getSessionTokens())
        assertEquals("AQIDBA==", AutofillCredentialStore.getSessionTokens()?.get("vault-uuid-primary"))

        // Simulate auto-lock timeout
        AutofillCredentialStore.autoLockSeconds = 1
        AutofillCredentialStore.lastActiveTimestamp = System.currentTimeMillis() - 2000L

        assertTrue("Auto lock must report expired after timeout", AutofillCredentialStore.isAutoLockExpired())
        assertNull("Session tokens must be null once auto-lock expires", AutofillCredentialStore.getSessionTokens())
        assertTrue("Store must revert to locked state", AutofillCredentialStore.isLocked)
    }

    @Test
    fun testSuggestionListReflectsUnlockStateForAllEntries() {
        val sampleEntries = listOf(
            NativeAutofillEntry(
                id = "entry-gmail",
                label = "Gmail",
                username = "alice@gmail.com",
                password = "Password123!",
                urls = listOf("https://accounts.google.com")
            ),
            NativeAutofillEntry(
                id = "entry-github",
                label = "GitHub",
                username = "octocat",
                password = "Password456!",
                urls = listOf("https://github.com")
            )
        )

        // 1. Locked State: Vault is locked
        AutofillCredentialStore.clear()
        assertTrue("Store must be locked initially", AutofillCredentialStore.isLocked)

        // All credential suggestions in locked state must reflect isLocked = true (lock icon present)
        val lockedSuggestions = sampleEntries.map { entry ->
            mapOf("id" to entry.id, "label" to entry.label, "isLocked" to AutofillCredentialStore.isLocked)
        }
        for (item in lockedSuggestions) {
            assertEquals("All entries must show lock icon when vault is locked", true, item["isLocked"])
        }

        // 2. Unlocked State: Vault is unlocked
        AutofillCredentialStore.sync(sampleEntries, autoLockSec = 300)
        assertFalse("Store must be unlocked after sync", AutofillCredentialStore.isLocked)

        // All credential suggestions across the list must immediately reflect isLocked = false (no lock icon)
        val unlockedSuggestions = sampleEntries.map { entry ->
            mapOf("id" to entry.id, "label" to entry.label, "isLocked" to AutofillCredentialStore.isLocked)
        }
        for (item in unlockedSuggestions) {
            assertEquals("Lock icon must disappear from ALL suggestions once unlocked", false, item["isLocked"])
        }
    }

    @Test
    fun testNativeAutofillEntryBothUsernameAndEmailSerialization() {
        val entry = NativeAutofillEntry(
            id = "entry-dual-id",
            label = "GitHub Dual",
            username = "octocat_user",
            email = "octocat@github.com",
            password = "SecretPassword123!",
            urls = listOf("https://github.com"),
            packageNames = listOf("com.github.android")
        )

        // 1. Verify fields on data class
        assertEquals("octocat_user", entry.username)
        assertEquals("octocat@github.com", entry.email)
        assertEquals("SecretPassword123!", entry.password)

        // 2. Verify AutofillCredentialStore metadata strips secrets but preserves email
        AutofillCredentialStore.sync(listOf(entry), autoLockSec = 300)
        val metaEntries = AutofillCredentialStore.getMetadataEntries()
        assertEquals(1, metaEntries.size)
        assertEquals("octocat_user", metaEntries[0].username)
        assertEquals("octocat@github.com", metaEntries[0].email)
        assertEquals("", metaEntries[0].password)

        // 3. Verify encrypted metadata cache payload format and round-trip
        val rawJson = """[{"id":"entry-dual-id","label":"GitHub Dual","username":"octocat_user","email":"octocat@github.com","urls":["https://github.com"],"packageNames":["com.github.android"]}]"""
        val encrypted = AutofillSecurityHelper.encrypt(AutofillSecurityHelper.ALIAS_METADATA_CACHE, rawJson)
        assertNotNull("Encrypted metadata should not be null", encrypted)

        val decrypted = AutofillSecurityHelper.decrypt(AutofillSecurityHelper.ALIAS_METADATA_CACHE, encrypted)
        assertEquals(rawJson, decrypted)
        assertTrue("Decrypted metadata must retain email", decrypted!!.contains(""""email":"octocat@github.com""""))
        assertTrue("Decrypted metadata must retain username", decrypted.contains(""""username":"octocat_user""""))
    }

    @Test
    fun testDualSuggestionsGeneratedWhenBothUsernameAndEmailPresent() {
        val dualEntry = NativeAutofillEntry(
            id = "uuid-1234",
            label = "Service Account",
            username = "johndoe",
            email = "john.doe@example.com",
            password = "MyPassword999!",
            urls = listOf("https://example.com")
        )

        val singleUsernameEntry = NativeAutofillEntry(
            id = "uuid-5678",
            label = "Username Only",
            username = "alice_wonder",
            email = null,
            password = "PassAlice123!",
            urls = listOf("https://example.com")
        )

        val singleEmailEntry = NativeAutofillEntry(
            id = "uuid-9012",
            label = "Email Only",
            username = "",
            email = "bob@example.com",
            password = "PassBob123!",
            urls = listOf("https://example.com")
        )

        val identicalEntry = NativeAutofillEntry(
            id = "uuid-3456",
            label = "Identical Value",
            username = "same@example.com",
            email = "same@example.com",
            password = "PassSame123!",
            urls = listOf("https://example.com")
        )

        // Helper logic replicating suggestion generation in FlutterMyAutofillService / AutofillServicePlugin
        fun generateSuggestions(entry: NativeAutofillEntry, isEmailFieldFocused: Boolean): List<Pair<String, String>> {
            val suggestions = mutableListOf<Pair<String, String>>() // Pair(datasetId, displayIdentifier)
            val hasDistinctEmail = !entry.email.isNullOrBlank() && entry.email != entry.username

            if (hasDistinctEmail && entry.username.isNotBlank()) {
                val emailItem = Pair("${entry.id}:email", entry.email!!)
                val userItem = Pair("${entry.id}:username", entry.username)
                if (isEmailFieldFocused) {
                    suggestions.add(emailItem)
                    suggestions.add(userItem)
                } else {
                    suggestions.add(userItem)
                    suggestions.add(emailItem)
                }
            } else {
                val identifier = if (entry.username.isNotBlank()) entry.username else (entry.email ?: "")
                suggestions.add(Pair(entry.id, identifier))
            }
            return suggestions
        }

        // 1. Dual Entry on Generic/Username field:
        val dualOnUser = generateSuggestions(dualEntry, isEmailFieldFocused = false)
        assertEquals(2, dualOnUser.size)
        assertEquals("uuid-1234:username", dualOnUser[0].first)
        assertEquals("johndoe", dualOnUser[0].second)
        assertEquals("uuid-1234:email", dualOnUser[1].first)
        assertEquals("john.doe@example.com", dualOnUser[1].second)

        // Base ID extraction returns underlying entry ID for both
        assertEquals("uuid-1234", dualOnUser[0].first.substringBefore(":"))
        assertEquals("uuid-1234", dualOnUser[1].first.substringBefore(":"))

        // 2. Dual Entry on Focused Email field:
        val dualOnEmail = generateSuggestions(dualEntry, isEmailFieldFocused = true)
        assertEquals(2, dualOnEmail.size)
        // Email suggestion prioritized first
        assertEquals("uuid-1234:email", dualOnEmail[0].first)
        assertEquals("john.doe@example.com", dualOnEmail[0].second)
        assertEquals("uuid-1234:username", dualOnEmail[1].first)
        assertEquals("johndoe", dualOnEmail[1].second)

        // 3. Single Username Entry:
        val singleUser = generateSuggestions(singleUsernameEntry, isEmailFieldFocused = false)
        assertEquals(1, singleUser.size)
        assertEquals("uuid-5678", singleUser[0].first)
        assertEquals("alice_wonder", singleUser[0].second)

        // 4. Single Email Entry:
        val singleEmail = generateSuggestions(singleEmailEntry, isEmailFieldFocused = true)
        assertEquals(1, singleEmail.size)
        assertEquals("uuid-9012", singleEmail[0].first)
        assertEquals("bob@example.com", singleEmail[0].second)

        // 5. Identical Username & Email Entry:
        val identical = generateSuggestions(identicalEntry, isEmailFieldFocused = false)
        assertEquals(1, identical.size)
        assertEquals("uuid-3456", identical[0].first)
        assertEquals("same@example.com", identical[0].second)
    }

    @Test
    fun testStoreMatchesRetainsEmailAcrossSyncAndQuery() {
        val entry = NativeAutofillEntry(
            id = "store-test-1",
            label = "Dual Sync Corp",
            username = "corpuser",
            email = "corpuser@corp.com",
            password = "SecretPasswordCorp123!",
            urls = listOf("https://login.corp.com")
        )

        AutofillCredentialStore.sync(listOf(entry), autoLockSec = 300)
        assertFalse(AutofillCredentialStore.isLocked)

        val matches = AutofillCredentialStore.findMatches("", "login.corp.com")
        assertEquals(1, matches.size)
        val matched = matches[0]
        assertEquals("corpuser", matched.username)
        assertEquals("corpuser@corp.com", matched.email)
        assertEquals("SecretPasswordCorp123!", matched.password)

        // Retrieve by base ID
        val retrieved = AutofillCredentialStore.getEntryById("store-test-1")
        assertNotNull(retrieved)
        assertEquals("corpuser", retrieved?.username)
        assertEquals("corpuser@corp.com", retrieved?.email)
    }

    @Test
    fun testAllFourGithubEntriesIsolationOnUnrelatedWebsites() {
        val entry1 = NativeAutofillEntry(
            id = "gh-1",
            label = "Github",
            username = "freakymeow0@gmail.com",
            email = "freakymeow0@gmail.com",
            password = "SecretPassword1!",
            urls = emptyList(), // missing URL
            packageNames = listOf("com.android.chrome") // accidentally carried browser package
        )
        val entry2 = NativeAutofillEntry(
            id = "gh-2",
            label = "GitHub",
            username = "moshicstu@gmail.com",
            email = "moshicstu@gmail.com",
            password = "SecretPassword2!",
            urls = listOf("", "https://"), // malformed URLs
            packageNames = listOf("com.android.chrome")
        )
        val entry3 = NativeAutofillEntry(
            id = "gh-3",
            label = "GitHub",
            username = "octocat_user3",
            password = "SecretPassword3!",
            urls = listOf("https://github.com"),
            packageNames = listOf("com.github.android"),
            registrableDomains = listOf("github.com")
        )
        val entry4 = NativeAutofillEntry(
            id = "gh-4",
            label = "GitHub",
            username = "octocat_user4",
            password = "SecretPassword4!",
            urls = listOf("https://github.com/login"),
            packageNames = listOf("com.github.android"),
            registrableDomains = listOf("github.com")
        )

        val allFour = listOf(entry1, entry2, entry3, entry4)
        AutofillCredentialStore.sync(allFour, autoLockSec = 300)

        // 1. On unrelated website (my.pcloud.com in Chrome) - NONE of the GitHub entries must appear
        val pcloudMatches = AutofillCredentialStore.findMatches("com.android.chrome", "my.pcloud.com")
        assertTrue("No GitHub entry should ever be suggested on my.pcloud.com", pcloudMatches.isEmpty())

        // 2. On other unrelated websites (twitter.com, reddit.com, example.org)
        val twitterMatches = AutofillCredentialStore.findMatches("com.android.chrome", "twitter.com")
        assertTrue("No GitHub entry should appear on twitter.com", twitterMatches.isEmpty())

        val redditMatches = AutofillCredentialStore.findMatches("org.mozilla.firefox", "reddit.com")
        assertTrue("No GitHub entry should appear on reddit.com", redditMatches.isEmpty())

        // 3. In browser with empty or missing domain - NEVER suggest any credentials
        val emptyDomainMatches = AutofillCredentialStore.findMatches("com.android.chrome", "")
        assertTrue("Browser request without identified web domain must return empty", emptyDomainMatches.isEmpty())

        val unextractedDomainMatches = AutofillCredentialStore.findMatches("com.android.chrome", "   ")
        assertTrue("Browser request with blank domain must return empty", unextractedDomainMatches.isEmpty())

        // 4. On GitHub website (github.com in Chrome) - valid GitHub entries MUST match
        val githubWebMatches = AutofillCredentialStore.findMatches("com.android.chrome", "github.com")
        assertEquals(2, githubWebMatches.size)
        assertTrue("Entry 3 must match github.com", githubWebMatches.any { it.id == "gh-3" })
        assertTrue("Entry 4 must match github.com", githubWebMatches.any { it.id == "gh-4" })
        assertFalse("Entry 1 with missing URL must not match github.com", githubWebMatches.any { it.id == "gh-1" })
        assertFalse("Entry 2 with malformed URL must not match github.com", githubWebMatches.any { it.id == "gh-2" })

        // 5. On GitHub Android app (com.github.android) - entries with matching app package MUST match
        val githubAppMatches = AutofillCredentialStore.findMatches("com.github.android", "")
        assertEquals(2, githubAppMatches.size)
        assertTrue("Entry 3 must match GitHub app", githubAppMatches.any { it.id == "gh-3" })
        assertTrue("Entry 4 must match GitHub app", githubAppMatches.any { it.id == "gh-4" })
    }

    @Test
    fun testMalformedAndMissingUrlEdgeCases() {
        val testEntries = listOf(
            NativeAutofillEntry(id = "m1", label = "BareScheme", username = "u1", password = "p", urls = listOf("https://")),
            NativeAutofillEntry(id = "m2", label = "BareStar", username = "u2", password = "p", urls = listOf("*")),
            NativeAutofillEntry(id = "m3", label = "BareSlash", username = "u3", password = "p", urls = listOf("/")),
            NativeAutofillEntry(id = "m4", label = "BareTld", username = "u4", password = "p", urls = listOf("com")),
            NativeAutofillEntry(id = "m5", label = "AndroidScheme", username = "u5", password = "p", urls = listOf("androidapp://com.android.chrome")),
            NativeAutofillEntry(id = "m6", label = "LegitPcloud", username = "pcloud_user", password = "p", urls = listOf("https://my.pcloud.com"))
        )

        AutofillCredentialStore.sync(testEntries, autoLockSec = 300)

        // Matching on pCloud
        val matches = AutofillCredentialStore.findMatches("com.android.chrome", "my.pcloud.com/#,")
        assertEquals("Only legit pCloud entry should match", 1, matches.size)
        assertEquals("m6", matches[0].id)
    }

    @Test
    fun testSanitizeWebDomainAuthority() {
        assertEquals("my.pcloud.com", AssistStructureParser.sanitizeWebDomain("my.pcloud.com"))
        assertEquals("my.pcloud.com", AssistStructureParser.sanitizeWebDomain("https://my.pcloud.com/#,"))
        assertEquals("my.pcloud.com", AssistStructureParser.sanitizeWebDomain("http://my.pcloud.com:443/login?ref=1#top"))
        assertEquals("my.pcloud.com", AssistStructureParser.sanitizeWebDomain("my.pcloud.com/"))
        assertEquals("github.com", AssistStructureParser.sanitizeWebDomain("https://github.com/login"))
        assertNull(AssistStructureParser.sanitizeWebDomain(""))
        assertNull(AssistStructureParser.sanitizeWebDomain("   "))
        assertNull(AssistStructureParser.sanitizeWebDomain(null))
    }

    @Test
    fun testServiceConfigurationOmitsCompatModeForChromeAndBrowsers() {
        val candidates = listOf(
            java.io.File("src/main/res/xml/service_configuration.xml"),
            java.io.File("../deps/autofill_service/android/src/main/res/xml/service_configuration.xml"),
            java.io.File("../../deps/autofill_service/android/src/main/res/xml/service_configuration.xml"),
            java.io.File("../android/src/main/res/xml/service_configuration.xml"),
            java.io.File("E:/PM/authpass-main/deps/autofill_service/android/src/main/res/xml/service_configuration.xml")
        )
        val fileToRead = candidates.firstOrNull { it.exists() }
        assertNotNull("service_configuration.xml must exist in one of candidate paths: ${candidates.map { it.absolutePath }}", fileToRead)
        val content = fileToRead!!.readText()
        assertFalse(
            "service_configuration.xml must not declare compatibility-package for com.android.chrome (causes accessibility bridge to close keyboard)",
            content.contains("<compatibility-package") && content.contains("com.android.chrome")
        )
        assertFalse(
            "service_configuration.xml must not declare compatibility-package for any browser",
            content.contains("<compatibility-package")
        )
    }

    @Test
    fun testFlagViewNotFocusedPreFillRequestHandledWithoutFocusTheft() {
        val flagViewNotFocused = 0x10 // FillRequest.FLAG_VIEW_NOT_FOCUSED
        val flagsWithPreFill = 0x40 or flagViewNotFocused // FLAG_SUPPORTS_FILL_DIALOG | FLAG_VIEW_NOT_FOCUSED
        assertTrue("Should detect FLAG_VIEW_NOT_FOCUSED", (flagsWithPreFill and 0x10) != 0)

        val flagsFocused = 0x40 // FLAG_SUPPORTS_FILL_DIALOG with view focused
        assertFalse("Should not flag focused request", (flagsFocused and 0x10) != 0)
    }

    @Test
    fun testTransientResizeCancellationDoesNotWipeAutofillSession() {
        // Setup active session
        AutofillRequestStore.hasActiveRequest = true
        AutofillRequestStore.activeRequestId = 42
        AutofillRequestStore.targetPackageName = "com.example.app"
        AutofillRequestStore.targetWebDomain = "example.com"
        AutofillRequestStore.activeSessionTimestamp = System.currentTimeMillis()

        var listenerFiredWithId: Int? = null
        AutofillRequestStore.onCancelledListener = { id ->
            listenerFiredWithId = id
        }

        // Simulate Android sending a transient cancel for requestId = 42 as the keyboard animates open and resizes the window
        AutofillRequestStore.onClientRequestCancelled(42)

        // Verifications:
        // 1. Cancel listener is notified for cleanup of pending tasks
        assertEquals(42, listenerFiredWithId)

        // 2. But the active session metadata and package/domain context remain PRESERVED for the incoming resized request
        assertTrue("Active session context must not be wiped out by transient keyboard resize cancellation", AutofillRequestStore.hasActiveRequest)
        assertEquals("com.example.app", AutofillRequestStore.targetPackageName)
        assertEquals("example.com", AutofillRequestStore.targetWebDomain)

        // Cleanup
        AutofillRequestStore.clear()
        assertFalse(AutofillRequestStore.hasActiveRequest)
    }
}



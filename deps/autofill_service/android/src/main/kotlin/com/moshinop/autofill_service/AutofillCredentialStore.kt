package com.moshinop.autofill_service

import android.content.Context
import mu.KotlinLogging
import org.json.JSONArray
import org.json.JSONObject
import java.net.URI

private val logger = KotlinLogging.logger {}
private const val PREFS_AUTOFILL_META = "keynest_autofill_meta"
private const val KEY_ENCRYPTED_METADATA = "encrypted_metadata_entries"
private const val KEY_LEGACY_METADATA = "metadata_entries"

data class NativeAutofillEntry(
    val id: String,
    val label: String,
    val username: String,
    val email: String? = null,
    val password: String = "",
    val urls: List<String> = emptyList(),
    val packageNames: List<String> = emptyList(),
    val registrableDomains: List<String> = emptyList(),
    val otp: String? = null,
    val otpSecret: String? = null,
    val otpAlgorithm: String = "SHA1",
    val otpPeriod: Int = 30,
    val otpDigits: Int = 6,
    val hasTotp: Boolean = false,
    val iconBytes: ByteArray? = null,
    val requireReprompt: Boolean = false,
    val lastUsedTimestamp: Long = 0L
)

data class NativePendingLogin(
    val entryId: String,
    val verifiedContext: String,
    val username: String,
    val createdAt: Long = System.currentTimeMillis()
)

data class SessionAuthRecord(
    val verifiedContext: String,
    val username: String,
    val createdAt: Long = System.currentTimeMillis()
)

object AutofillCredentialStore {
    @Volatile
    var isLocked: Boolean = true

    @Volatile
    var autoLockSeconds: Int = 300 // Default 5 minutes (-1 = never, 0 = immediate)

    @Volatile
    var lastUnlockedTimestamp: Long = 0L

    @Volatile
    var lastActiveTimestamp: Long = 0L

    private val lock = Any()
    // In-memory unlocked entries containing full credentials including decrypted passwords
    private val _entries = mutableListOf<NativeAutofillEntry>()
    // In-memory metadata entries containing ONLY non-secret account identification (NO passwords, NO OTP secrets)
    private val _metadataEntries = mutableListOf<NativeAutofillEntry>()
    private var _pendingLogin: NativePendingLogin? = null
    // In-memory session tokens (UUID -> base64 composite key hash) for persistent unlocked session across app instances
    @Volatile
    private var _sessionTokens: Map<String, String>? = null

    fun cacheSessionTokens(tokens: Map<String, String>) {
        synchronized(lock) {
            _sessionTokens = tokens.toMap()
            isLocked = false
            val now = System.currentTimeMillis()
            lastUnlockedTimestamp = now
            lastActiveTimestamp = now
        }
    }

    fun getSessionTokens(): Map<String, String>? {
        synchronized(lock) {
            if (isAutoLockExpired()) {
                clear()
                return null
            }
            return _sessionTokens
        }
    }

    fun clearSessionTokens() {
        synchronized(lock) {
            _sessionTokens = null
        }
    }

    // Well-known associated Android app package to web domain mappings
    private val associatedAppMap = mapOf(
        "com.github.android" to listOf("github.com"),
        "com.twitter.android" to listOf("twitter.com", "x.com"),
        "com.facebook.katana" to listOf("facebook.com"),
        "com.facebook.orca" to listOf("messenger.com", "facebook.com"),
        "com.google.android.youtube" to listOf("youtube.com", "google.com"),
        "com.google.android.gm" to listOf("gmail.com", "google.com"),
        "com.instagram.android" to listOf("instagram.com"),
        "com.linkedin.android" to listOf("linkedin.com"),
        "com.reddit.frontpage" to listOf("reddit.com"),
        "org.telegram.messenger" to listOf("telegram.org"),
        "com.discord" to listOf("discord.com"),
        "com.spotify.music" to listOf("spotify.com"),
        "com.amazon.mShop.android.shopping" to listOf("amazon.com"),
        "com.netflix.mediaclient" to listOf("netflix.com"),
        "com.paypal.android.p2pmobile" to listOf("paypal.com"),
        "com.ubercab" to listOf("uber.com"),
        "com.ubercab.eats" to listOf("ubereats.com", "uber.com"),
        "me.lyft.android" to listOf("lyft.com"),
        "com.slack" to listOf("slack.com"),
        "us.zoom.videomeetings" to listOf("zoom.us"),
        "com.zhiliaoapp.musically" to listOf("tiktok.com"),
        "com.pinterest" to listOf("pinterest.com"),
        "com.valvesoftware.android.steam.community" to listOf("steampowered.com", "steamcommunity.com"),
        "com.dropbox.android" to listOf("dropbox.com"),
        "com.gitlab.mobile" to listOf("gitlab.com"),
        "com.whatsapp" to listOf("whatsapp.com"),
        "org.thoughtcrime.securesms" to listOf("signal.org"),
        "com.ebay.mobile" to listOf("ebay.com"),
        "com.airbnb.android" to listOf("airbnb.com"),
        "com.booking" to listOf("booking.com"),
        "ch.protonmail.android" to listOf("proton.me", "protonmail.com"),
        "com.bitwarden.mobile" to listOf("bitwarden.com"),
        "com.duolingo" to listOf("duolingo.com"),
        "com.adobe.reader" to listOf("adobe.com"),
        "com.microsoft.teams" to listOf("teams.microsoft.com", "microsoft.com"),
        "com.microsoft.office.outlook" to listOf("outlook.com", "microsoft.com"),
        "com.microsoft.office.word" to listOf("office.com", "microsoft.com"),
        "com.snapchat.android" to listOf("snapchat.com"),
        "tv.twitch.android.app" to listOf("twitch.tv"),
        "com.tripadvisor.tripadvisor" to listOf("tripadvisor.com"),
        "com.yahoo.mobile.client.android.mail" to listOf("yahoo.com"),
        "com.medium.reader" to listOf("medium.com"),
        "com.quora.android" to listOf("quora.com"),
        "com.vimeo.android.videoapp" to listOf("vimeo.com"),
        "com.atlassian.jira" to listOf("atlassian.com", "jira.com"),
        "com.atlassian.confluence" to listOf("atlassian.com", "confluence.com")
    )

    fun sync(unlockedEntries: List<NativeAutofillEntry>, autoLockSec: Int = 300, context: Context? = null) {
        synchronized(lock) {
            _entries.clear()
            _entries.addAll(unlockedEntries)

            // Cache sanitized metadata only: passwords and OTP secrets are explicitly stripped
            _metadataEntries.clear()
            _metadataEntries.addAll(unlockedEntries.map {
                it.copy(password = "", otp = null, otpSecret = null)
            })

            autoLockSeconds = autoLockSec
            val now = System.currentTimeMillis()
            lastUnlockedTimestamp = now
            lastActiveTimestamp = now
            isLocked = false

            if (context != null) {
                saveMetadataToDisk(context)
            }
        }
    }

    fun loadMetadata(context: Context) {
        synchronized(lock) {
            if (_metadataEntries.isNotEmpty()) return
            try {
                val iconsDir = java.io.File(context.filesDir, "autofill_icons")
                val prefs = context.getSharedPreferences(PREFS_AUTOFILL_META, Context.MODE_PRIVATE)

                // 1. Try to read encrypted metadata first
                val encrypted = prefs.getString(KEY_ENCRYPTED_METADATA, null)
                var jsonStr: String? = null

                if (encrypted != null) {
                    jsonStr = AutofillSecurityHelper.decrypt(
                        AutofillSecurityHelper.ALIAS_METADATA_CACHE,
                        encrypted
                    )
                    if (jsonStr == null) {
                        logger.warn { "Corrupted or unrecoverable encrypted metadata cache; clearing" }
                        prefs.edit().remove(KEY_ENCRYPTED_METADATA).apply()
                    } else if (prefs.contains(KEY_LEGACY_METADATA)) {
                        // Clean up legacy plaintext if still present from interrupted write
                        prefs.edit().remove(KEY_LEGACY_METADATA).apply()
                    }
                }

                // 2. If no valid encrypted data exists, check for legacy plaintext to migrate
                if (jsonStr == null) {
                    val legacyJson = prefs.getString(KEY_LEGACY_METADATA, null)
                    if (legacyJson != null) {
                        // Migrate safely: encrypt and persist successfully BEFORE removing legacy plaintext
                        val newEncrypted = AutofillSecurityHelper.encrypt(
                            AutofillSecurityHelper.ALIAS_METADATA_CACHE,
                            legacyJson
                        )
                        if (newEncrypted != null) {
                            prefs.edit()
                                .putString(KEY_ENCRYPTED_METADATA, newEncrypted)
                                .remove(KEY_LEGACY_METADATA)
                                .apply()
                        }
                        jsonStr = legacyJson
                    }
                }

                if (jsonStr == null) return

                val array = JSONArray(jsonStr)
                _metadataEntries.clear()
                for (i in 0 until array.length()) {
                    val obj = array.getJSONObject(i)
                    val id = obj.getString("id")
                    val urlsList = mutableListOf<String>()
                    val urlsArr = obj.optJSONArray("urls")
                    if (urlsArr != null) {
                        for (u in 0 until urlsArr.length()) {
                            val str = urlsArr.getString(u).trim()
                            if (str.isNotEmpty() && !str.startsWith("androidapp://", ignoreCase = true)) {
                                urlsList.add(str)
                            }
                        }
                    }
                    val pkgsList = mutableListOf<String>()
                    val pkgsArr = obj.optJSONArray("packageNames")
                    if (pkgsArr != null) {
                        for (p in 0 until pkgsArr.length()) {
                            val pkg = pkgsArr.getString(p).trim().lowercase()
                            if (pkg.isNotEmpty() && !AssistStructureParser.isBrowserPackage(pkg)) {
                                pkgsList.add(pkg)
                            }
                        }
                    }
                    val regDomainsList = mutableListOf<String>()
                    val regDomainsArr = obj.optJSONArray("registrableDomains")
                    if (regDomainsArr != null) {
                        for (r in 0 until regDomainsArr.length()) {
                            val dom = regDomainsArr.getString(r).trim().lowercase().removePrefix("www.").trim('.')
                            if (dom.isNotEmpty() && dom.contains(".")) {
                                regDomainsList.add(dom)
                            }
                        }
                    }
                    val iconFile = java.io.File(iconsDir, "$id.png")
                    val iconBytes = if (iconFile.exists()) {
                        try { iconFile.readBytes() } catch (_: Exception) { null }
                    } else null

                    _metadataEntries.add(
                        NativeAutofillEntry(
                            id = id,
                            label = obj.optString("label", ""),
                            username = obj.optString("username", ""),
                            email = obj.optString("email", "").takeIf { it.isNotBlank() },
                            password = "", // Secrets are NEVER written to metadata cache
                            urls = urlsList,
                            packageNames = pkgsList,
                            registrableDomains = regDomainsList,
                            otp = null,
                            otpSecret = null,
                            hasTotp = obj.optBoolean("hasTotp", false),
                            iconBytes = iconBytes,
                            lastUsedTimestamp = obj.optLong("lastUsedTimestamp", 0L)
                        )
                    )
                }
            } catch (e: Exception) {
                logger.warn { "Error loading metadata: ${e.message}" }
            }
        }
    }

    private fun saveMetadataToDisk(context: Context) {
        try {
            val iconsDir = java.io.File(context.filesDir, "autofill_icons").apply { mkdirs() }
            val array = JSONArray()
            for (entry in _metadataEntries) {
                val obj = JSONObject().apply {
                    put("id", entry.id)
                    put("label", entry.label)
                    put("username", entry.username)
                    if (!entry.email.isNullOrBlank()) {
                        put("email", entry.email)
                    }
                    put("urls", JSONArray(entry.urls))
                    put("packageNames", JSONArray(entry.packageNames))
                    put("registrableDomains", JSONArray(entry.registrableDomains))
                    put("hasTotp", entry.hasTotp)
                    put("lastUsedTimestamp", entry.lastUsedTimestamp)
                }
                array.put(obj)
                if (entry.iconBytes != null && entry.iconBytes.isNotEmpty()) {
                    try {
                        java.io.File(iconsDir, "${entry.id}.png").writeBytes(entry.iconBytes)
                    } catch (_: Exception) {}
                }
            }
            val jsonStr = array.toString()
            val encrypted = AutofillSecurityHelper.encrypt(
                AutofillSecurityHelper.ALIAS_METADATA_CACHE,
                jsonStr
            )
            if (encrypted != null) {
                context.getSharedPreferences(PREFS_AUTOFILL_META, Context.MODE_PRIVATE)
                    .edit()
                    .putString(KEY_ENCRYPTED_METADATA, encrypted)
                    .remove(KEY_LEGACY_METADATA)
                    .apply()
            } else {
                logger.warn { "Encryption of metadata cache failed; skipping disk persistence" }
            }
        } catch (e: Exception) {
            logger.warn { "Error saving metadata cache: ${e.message}" }
        }
    }

    fun setAutoLockSettings(seconds: Int) {
        synchronized(lock) {
            autoLockSeconds = seconds
            if (isAutoLockExpired()) {
                clear()
            }
        }
    }

    fun touchActive() {
        synchronized(lock) {
            if (!isLocked || _sessionTokens != null) {
                lastActiveTimestamp = System.currentTimeMillis()
            }
        }
    }

    fun isAutoLockExpired(): Boolean {
        synchronized(lock) {
            if (isLocked && _sessionTokens == null) return true
            if (autoLockSeconds < 0) return false // Never lock
            if (autoLockSeconds == 0) return true // Immediate lock
            val now = System.currentTimeMillis()
            val elapsed = (now - lastActiveTimestamp) / 1000
            return elapsed >= autoLockSeconds
        }
    }

    fun isUnlockedAndActive(): Boolean {
        synchronized(lock) {
            if (isLocked) return false
            if (isAutoLockExpired()) {
                clear()
                return false
            }
            return true
        }
    }

    fun clear() {
        synchronized(lock) {
            _entries.clear()
            _sessionTokens = null
            _pendingLogin = null
            _sessionAuthMap.clear()
            lastUnlockedTimestamp = 0L
            lastActiveTimestamp = 0L
            isLocked = true
            AutofillRequestStore.clear()
            // Non-sensitive _metadataEntries are safely retained so suggestions
            // can still be displayed while locked without exposing secrets
        }
    }

    fun lock() {
        clear()
    }

    fun clearAll(context: Context? = null) {
        synchronized(lock) {
            clear()
            _sessionTokens = null
            _metadataEntries.clear()
            if (context != null) {
                try {
                    val iconsDir = java.io.File(context.filesDir, "autofill_icons")
                    if (iconsDir.exists()) {
                        iconsDir.deleteRecursively()
                    }
                    context.getSharedPreferences(PREFS_AUTOFILL_META, Context.MODE_PRIVATE)
                        .edit()
                        .remove(KEY_ENCRYPTED_METADATA)
                        .remove(KEY_LEGACY_METADATA)
                        .apply()
                    AutofillSecurityHelper.deleteKey(AutofillSecurityHelper.ALIAS_METADATA_CACHE)
                } catch (e: Exception) {
                    logger.warn { "Error clearing metadata from disk: ${e.message}" }
                }
            }
        }
    }

    fun getEntries(): List<NativeAutofillEntry> {
        synchronized(lock) {
            return if (isUnlockedAndActive()) {
                _entries.toList()
            } else {
                _metadataEntries.map { it.copy(password = "", otp = null, otpSecret = null) }
            }
        }
    }

    fun getMetadataEntries(): List<NativeAutofillEntry> {
        synchronized(lock) {
            return _metadataEntries.map { it.copy(password = "", otp = null, otpSecret = null) }
        }
    }

    fun getEntryById(id: String): NativeAutofillEntry? {
        synchronized(lock) {
            val entry = if (isUnlockedAndActive()) {
                _entries.firstOrNull { it.id == id }
            } else {
                null
            }
            return entry ?: _metadataEntries.firstOrNull { it.id == id }?.copy(password = "", otp = null, otpSecret = null)
        }
    }

    fun rememberPendingLogin(entryId: String, verifiedContext: String, username: String) {
        synchronized(lock) {
            _pendingLogin = NativePendingLogin(
                entryId = entryId,
                verifiedContext = verifiedContext,
                username = username,
                createdAt = System.currentTimeMillis()
            )
        }
    }

    fun getValidPendingLogin(currentContext: String): NativePendingLogin? {
        synchronized(lock) {
            val record = _pendingLogin ?: return null
            val age = System.currentTimeMillis() - record.createdAt
            if (age > 120_000L) { // 2 minute TTL
                _pendingLogin = null
                return null
            }

            val current = currentContext.trim().lowercase()
            val remembered = record.verifiedContext.trim().lowercase()
            if (current.isEmpty() || remembered.isEmpty()) return null

            val matches = current == remembered ||
                    current.endsWith(".$remembered") ||
                    remembered.endsWith(".$current") ||
                    isRegistrableDomainMatch(current, remembered)
            return if (matches) record else null
        }
    }

    fun clearPendingLogin() {
        synchronized(lock) {
            _pendingLogin = null
        }
    }

    private val _sessionAuthMap = mutableMapOf<String, SessionAuthRecord>()

    fun recordSessionUsername(context: String, username: String) {
        val trimmedContext = context.trim().lowercase()
        val trimmedUser = username.trim()
        if (trimmedContext.isEmpty() || trimmedUser.isEmpty()) return
        synchronized(lock) {
            _sessionAuthMap[trimmedContext] = SessionAuthRecord(
                verifiedContext = trimmedContext,
                username = trimmedUser,
                createdAt = System.currentTimeMillis()
            )
        }
    }

    fun getSessionUsername(currentContext: String): String? {
        val trimmedCurrent = currentContext.trim().lowercase()
        if (trimmedCurrent.isEmpty()) return null
        synchronized(lock) {
            val now = System.currentTimeMillis()
            _sessionAuthMap.entries.removeAll { now - it.value.createdAt > 300_000L }

            for ((key, record) in _sessionAuthMap) {
                if (trimmedCurrent == key ||
                    trimmedCurrent.endsWith(".$key") ||
                    key.endsWith(".$trimmedCurrent") ||
                    isRegistrableDomainMatch(trimmedCurrent, key)
                ) {
                    return record.username
                }
            }
            return null
        }
    }

    fun clearSessionAuth(context: String? = null) {
        synchronized(lock) {
            if (context == null) {
                _sessionAuthMap.clear()
            } else {
                val trimmed = context.trim().lowercase()
                _sessionAuthMap.remove(trimmed)
            }
        }
    }

    fun getAssociatedWebDomain(packageName: String): String? {
        val normalized = packageName.trim().lowercase()
        return associatedAppMap[normalized]?.firstOrNull()
    }

    fun deriveDomainFromPackage(packageName: String): String? {
        val parts = packageName.trim().lowercase().split(".").filter { it.isNotEmpty() }
        if (parts.size >= 2) {
            val tld = parts[0]
            val brand = parts[1]
            val knownTlds = setOf(
                "com", "org", "net", "io", "app", "co", "us", "de", "uk",
                "ch", "fr", "it", "es", "nl", "ca", "in", "me", "tv"
            )
            if (knownTlds.contains(tld) && brand.length >= 2) {
                return "$brand.$tld"
            }
        }
        return null
    }

    /**
     * Resolves matching credentials against target package and domain.
     * Evaluates package equality, associated app packages, exact host, and eTLD+1 base domains.
     * Strictly rejects unsafe lookalike substrings.
     */
    fun findMatches(targetPackage: String, targetDomain: String): List<NativeAutofillEntry> {
        synchronized(lock) {
            val sourceEntries = if (isUnlockedAndActive()) {
                touchActive()
                _entries
            } else {
                _metadataEntries.map { it.copy(password = "", otp = null, otpSecret = null) }
            }
            if (sourceEntries.isEmpty()) return emptyList()

            val normalizedPackage = targetPackage.trim().lowercase()
            val normalizedDomain = AssistStructureParser.sanitizeWebDomain(targetDomain)?.lowercase() ?: ""
            val isBrowser = AssistStructureParser.isBrowserPackage(normalizedPackage)
            val hasTargetDomain = normalizedDomain.isNotEmpty()

            // If a web browser requests credentials without an identified web domain,
            // never suggest stored logins (prevents leakages on unknown/unrelated pages)
            if (isBrowser && !hasTargetDomain) {
                return emptyList()
            }

            val associatedDomains = if (normalizedPackage.isNotEmpty() && !isBrowser) {
                associatedAppMap[normalizedPackage] ?: emptyList()
            } else {
                emptyList()
            }

            val derivedDomain = if (normalizedPackage.isNotEmpty() && !isBrowser) {
                deriveDomainFromPackage(normalizedPackage)
            } else null


            val scoredMatches = mutableListOf<Pair<NativeAutofillEntry, Int>>()

            for (entry in sourceEntries) {
                var score = 0

                // 1. Check direct package name match (strictly for native non-browser apps)
                if (normalizedPackage.isNotEmpty() && !isBrowser && !hasTargetDomain) {
                    val packageMatch = entry.packageNames.any { pkg ->
                        val cleanPkg = pkg.trim().lowercase()
                        cleanPkg.isNotBlank() &&
                                !AssistStructureParser.isBrowserPackage(cleanPkg) &&
                                cleanPkg == normalizedPackage
                    }
                    if (packageMatch) {
                        score = maxOf(score, 100)
                    }
                }

                // 2. Check associated app domain match (native apps only)
                if (associatedDomains.isNotEmpty() && !isBrowser) {
                    for (entryUrl in entry.urls) {
                        val host = extractHost(entryUrl)
                        if (host != null && associatedDomains.any { it == host || host.endsWith(".$it") || isRegistrableDomainMatch(host, it) }) {
                            score = maxOf(score, 90)
                        }
                    }
                }

                // 2b. Check derived package domain match (reverse domain notation, e.g. com.todoist -> todoist.com)
                if (derivedDomain != null && !isBrowser) {
                    for (entryUrl in entry.urls) {
                        val host = extractHost(entryUrl)
                        if (host != null && (host == derivedDomain || host.endsWith(".$derivedDomain") || isRegistrableDomainMatch(host, derivedDomain))) {
                            score = maxOf(score, 75)
                        }
                    }
                }


                // 3. Check web domain match (based strictly on legitimate web origin matching)
                if (hasTargetDomain) {
                    val cleanTargetHost = normalizedDomain.removePrefix("www.").trim('.')
                    val targetRegistrable = getRegistrableDomain(cleanTargetHost)

                    if (cleanTargetHost.isNotEmpty() && targetRegistrable.isNotEmpty()) {
                        // 3a. Direct match against pre-computed registrableDomains from Dart
                        if (entry.registrableDomains.isNotEmpty()) {
                            if (entry.registrableDomains.any {
                                val clean = it.trim().lowercase().removePrefix("www.").trim('.')
                                clean.isNotEmpty() && (clean == targetRegistrable || clean == cleanTargetHost)
                            }) {
                                score = maxOf(score, 80)
                            }
                        }

                        // 3b. Exact host & fallback registrable domain match
                        for (entryUrl in entry.urls) {
                            val host = extractHost(entryUrl) ?: continue
                            val cleanEntryHost = host.removePrefix("www.").trim('.')
                            if (cleanEntryHost.isEmpty()) continue

                            if (cleanEntryHost == cleanTargetHost) {
                                // Exact host match
                                score = maxOf(score, 100)
                            } else if (isRegistrableDomainMatch(cleanEntryHost, cleanTargetHost)) {
                                // Subdomain / registrable domain match
                                score = maxOf(score, 80)
                            }
                        }
                    }
                }

                if (score > 0) {
                    scoredMatches.add(entry to score)
                }
            }

            // Sort by match score descending, then by last used timestamp
            val resultList = scoredMatches
                .sortedWith(compareByDescending<Pair<NativeAutofillEntry, Int>> { it.second }
                    .thenByDescending { it.first.lastUsedTimestamp })
                .map { it.first }
                .toMutableList()

            // If a credential was explicitly selected or remembered for this context, prepend it
            val contextKey = if (hasTargetDomain) normalizedDomain else normalizedPackage
            val pending = getValidPendingLogin(contextKey)
            if (pending != null) {
                val pendingEntry = sourceEntries.firstOrNull { it.id == pending.entryId }
                if (pendingEntry != null) {
                    // For web requests, ensure pending entry genuinely matches this domain before prioritizing
                    if (!hasTargetDomain || resultList.any { it.id == pendingEntry.id }) {
                        resultList.removeAll { it.id == pendingEntry.id }
                        resultList.add(0, pendingEntry)
                    }
                }
            }
            return resultList
        }
    }

    fun extractHost(urlStr: String): String? {
        val trimmed = urlStr.trim()
        if (trimmed.isEmpty()) return null
        if (trimmed.startsWith("androidapp://", ignoreCase = true)) return null

        return try {
            val uri = if (!trimmed.startsWith("http://", ignoreCase = true) && !trimmed.startsWith("https://", ignoreCase = true)) {
                URI("https://$trimmed")
            } else {
                URI(trimmed)
            }
            val host = uri.host?.lowercase()?.trim('.')
            if (host.isNullOrBlank() || host.contains("*") || host.contains("/") || host.contains(" ") || host.contains("%")) {
                null
            } else {
                host
            }
        } catch (e: Exception) {
            null
        }
    }

    private fun isIpAddress(host: String): Boolean {
        if (host.contains(":")) return true // IPv6
        val parts = host.split(".")
        if (parts.size != 4) return false
        return parts.all { it.toIntOrNull()?.let { num -> num in 0..255 } == true }
    }

    fun getRegistrableDomain(host: String): String {
        val cleanHost = host.trim().lowercase().removePrefix("www.")
        if (cleanHost.isEmpty() || cleanHost == "localhost" || isIpAddress(cleanHost)) {
            return cleanHost
        }

        val parts = cleanHost.split(".").filter { it.isNotEmpty() }
        if (parts.size < 2) return cleanHost

        // 1. Check exception rules (e.g. !city.kawasaki.jp -> city.kawasaki.jp)
        for (i in parts.indices) {
            val candidate = parts.subList(i, parts.size).joinToString(".")
            if (PublicSuffixData.EXCEPTION_RULES.contains(candidate)) {
                return candidate
            }
        }

        // 2. Check multi-part suffixes and wildcards from longest suffix to shortest
        var longestSuffixPartsCount = 0
        for (i in 1 until parts.size) {
            val suffixCandidate = parts.subList(i, parts.size).joinToString(".")
            val rootCandidate = if (i + 1 < parts.size) parts.subList(i + 1, parts.size).joinToString(".") else parts.last()

            if (PublicSuffixData.MULTI_PART_SUFFIXES.contains(suffixCandidate)) {
                val candidateLen = parts.size - i
                if (candidateLen > longestSuffixPartsCount) {
                    longestSuffixPartsCount = candidateLen
                }
            } else if (PublicSuffixData.WILDCARD_ROOTS.contains(rootCandidate)) {
                val candidateLen = parts.size - i
                if (candidateLen > longestSuffixPartsCount) {
                    longestSuffixPartsCount = candidateLen
                }
            }
        }

        if (longestSuffixPartsCount > 0) {
            val domainStartIndex = parts.size - longestSuffixPartsCount - 1
            if (domainStartIndex >= 0) {
                return parts.subList(domainStartIndex, parts.size).joinToString(".")
            }
            return cleanHost
        }

        // Standard single-part TLD (e.g. "example.com" or "sub.example.com")
        return "${parts[parts.size - 2]}.${parts.last()}"
    }

    fun isRegistrableDomainMatch(host1: String, host2: String): Boolean {
        val clean1 = host1.trim().lowercase().removePrefix("www.").trim('.')
        val clean2 = host2.trim().lowercase().removePrefix("www.").trim('.')
        if (clean1.isEmpty() || clean2.isEmpty()) return false
        if (clean1 == clean2) return true

        // IP addresses, localhost, or single-label hosts can only ever match exactly
        if (clean1 == "localhost" || clean2 == "localhost" || isIpAddress(clean1) || isIpAddress(clean2)) {
            return false
        }

        val base1 = getRegistrableDomain(clean1)
        val base2 = getRegistrableDomain(clean2)

        return base1.isNotEmpty() && base2.isNotEmpty() && base1 == base2
    }
}

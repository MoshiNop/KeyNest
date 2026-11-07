package com.moshinop.autofill_service

import android.app.assist.AssistStructure
import android.os.Build
import android.util.Base64
import android.view.autofill.AutofillId
import androidx.annotation.RequiresApi
import mu.KotlinLogging
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.concurrent.ConcurrentHashMap

private val logger = KotlinLogging.logger {}

/**
 * Thread-safe persistent singleton store that preserves the active autofill request context
 * across Activity transitions, biometric authentication prompts, Flutter route navigation,
 * and activity recreation.
 */
object AutofillRequestStore {
    const val REQUEST_TTL_MS = 300_000L // 5 min TTL
    @Volatile
    var pendingAuthLevel: String? = null

    @Volatile
    var targetPackageName: String? = null

    @Volatile
    var targetWebDomain: String? = null

    @Volatile
    var originatingPackageName: String? = null

    @Volatile
    var focusedAutofillId: AutofillId? = null

    @Volatile
    var usernameFieldIds: List<AutofillId> = emptyList()

    @Volatile
    var emailFieldIds: List<AutofillId> = emptyList()

    @Volatile
    var passwordFieldIds: List<AutofillId> = emptyList()

    @Volatile
    var confirmPwFieldIds: List<AutofillId> = emptyList()

    @Volatile
    var otpFieldIds: List<AutofillId> = emptyList()

    @Volatile
    var allFieldIds: List<AutofillId> = emptyList()

    @Volatile
    private var _latestStructure: AssistStructure? = null
    var latestStructure: AssistStructure?
        get() {
            if (isExpired()) {
                clear()
                return null
            }
            return _latestStructure
        }
        set(value) {
            _latestStructure = value
        }

    @Volatile
    private var _latestParser: AssistStructureParser? = null
    var latestParser: AssistStructureParser?
        get() {
            if (isExpired()) {
                clear()
                return null
            }
            return _latestParser
        }
        set(value) {
            _latestParser = value
        }

    @Volatile
    var selectedEntryId: String? = null

    @Volatile
    var activeRequestId: Int? = null

    @Volatile
    var activeSessionTimestamp: Long = 0L

    @Volatile
    var hasActiveRequest: Boolean = false

    fun isExpired(): Boolean {
        if (!hasActiveRequest || activeSessionTimestamp <= 0L) {
            return false
        }
        return (System.currentTimeMillis() - activeSessionTimestamp) >= REQUEST_TTL_MS
    }

    var onCancelledListener: ((Int) -> Unit)? = null

    private data class FastFillGrant(
        val requestId: Int,
        val entryId: String,
        val createdAt: Long,
        val tokenBytes: ByteArray
    )

    private val secureRandom = SecureRandom()
    private val fastFillGrants = ConcurrentHashMap<String, FastFillGrant>()

    private fun encodeUrlBase64(bytes: ByteArray): String {
        return try {
            Base64.encodeToString(bytes, Base64.URL_SAFE or Base64.NO_WRAP)
        } catch (_: Throwable) {
            java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
        }
    }

    private fun decodeUrlBase64(str: String): ByteArray {
        return try {
            Base64.decode(str, Base64.URL_SAFE or Base64.NO_WRAP)
        } catch (_: Throwable) {
            java.util.Base64.getUrlDecoder().decode(str)
        }
    }

    /**
     * Issues a 256-bit one-time capability nonce bound to [requestId] and [entryId]
     * for authenticating `FILL_ENTRY` intents on exported `MainActivity`.
     */
    fun issueFastFillToken(requestId: Int, entryId: String): String {
        val now = System.currentTimeMillis()
        fastFillGrants.entries.removeIf { (_, grant) -> (now - grant.createdAt) >= REQUEST_TTL_MS }
        val bytes = ByteArray(32)
        secureRandom.nextBytes(bytes)
        val token = encodeUrlBase64(bytes)
        fastFillGrants[token] = FastFillGrant(
            requestId = requestId,
            entryId = entryId,
            createdAt = now,
            tokenBytes = bytes
        )
        return token
    }

    /**
     * Verifies a `FILL_ENTRY` capability nonce in constant time without consuming it
     * (used when recording `selectedEntryId` while the vault is still locked prior to biometric auth).
     */
    fun verifyFastFillToken(token: String?, requestId: Int, entryId: String): Boolean {
        if (token.isNullOrBlank() || entryId.isBlank()) return false
        val grant = fastFillGrants[token] ?: return false
        val now = System.currentTimeMillis()
        if ((now - grant.createdAt) >= REQUEST_TTL_MS) {
            fastFillGrants.remove(token)
            return false
        }
        val candidateBytes = try {
            decodeUrlBase64(token)
        } catch (_: Exception) {
            return false
        }
        val tokenValid = MessageDigest.isEqual(grant.tokenBytes, candidateBytes)
        val reqMatches = requestId < 0 || grant.requestId == requestId
        return tokenValid && reqMatches && grant.entryId == entryId
    }

    /**
     * Verifies and atomically consumes a one-time `FILL_ENTRY` capability nonce in constant time.
     */
    fun consumeFastFillToken(token: String?, requestId: Int, entryId: String): Boolean {
        if (token.isNullOrBlank() || entryId.isBlank()) return false
        val grant = fastFillGrants.remove(token) ?: return false
        val now = System.currentTimeMillis()
        if ((now - grant.createdAt) >= REQUEST_TTL_MS) return false
        val candidateBytes = try {
            decodeUrlBase64(token)
        } catch (_: Exception) {
            return false
        }
        val tokenValid = MessageDigest.isEqual(grant.tokenBytes, candidateBytes)
        val reqMatches = requestId < 0 || grant.requestId == requestId
        return tokenValid && reqMatches && grant.entryId == entryId
    }

    @RequiresApi(Build.VERSION_CODES.O)
    fun saveRequest(
        authLevel: String,
        packageName: String,
        webDomain: String,
        structure: AssistStructure,
        parser: AssistStructureParser,
        requestId: Int? = null,
        originatingPackage: String? = null,
        entryId: String? = null,
        overrideUsernameIds: List<AutofillId>? = null,
        overrideEmailIds: List<AutofillId>? = null,
        overridePasswordIds: List<AutofillId>? = null,
        overrideConfirmPwIds: List<AutofillId>? = null,
        overrideOtpIds: List<AutofillId>? = null
    ) {
        val isSameContext = (packageName.isNotBlank() && packageName == targetPackageName) ||
                (webDomain.isNotBlank() && webDomain == targetWebDomain)
        activeRequestId = requestId
        if (entryId != null) {
            selectedEntryId = entryId
        } else if (!isSameContext) {
            selectedEntryId = null
        }
        activeSessionTimestamp = System.currentTimeMillis()
        pendingAuthLevel = authLevel
        targetPackageName = packageName
        targetWebDomain = webDomain
        originatingPackageName = originatingPackage
        latestStructure = structure
        latestParser = parser

        val userFields = overrideUsernameIds ?: ((parser.fieldIds[AutofillInputType.UserName]?.map { it.autofillId } ?: emptyList()).distinct())
        val emailFields = overrideEmailIds ?: ((parser.fieldIds[AutofillInputType.Email]?.map { it.autofillId } ?: emptyList()).distinct())
        val pwFields = overridePasswordIds ?: (((parser.fieldIds[AutofillInputType.Password]?.map { it.autofillId } ?: emptyList()) +
                (parser.fieldIds[AutofillInputType.NewPassword]?.map { it.autofillId } ?: emptyList()) +
                (parser.fieldIds[AutofillInputType.CurrentPassword]?.map { it.autofillId } ?: emptyList())).distinct())
        val confirmFields = overrideConfirmPwIds ?: ((parser.fieldIds[AutofillInputType.ConfirmPassword]?.map { it.autofillId } ?: emptyList()).distinct())
        val otpFields = overrideOtpIds ?: ((parser.fieldIds[AutofillInputType.Otp]?.map { it.autofillId } ?: emptyList()).distinct())

        usernameFieldIds = userFields
        emailFieldIds = emailFields
        passwordFieldIds = pwFields
        confirmPwFieldIds = confirmFields
        otpFieldIds = otpFields
        allFieldIds = (parser.autoFillIds + userFields + pwFields + confirmFields + otpFields).distinct()
        focusedAutofillId = parser.allNodes.firstOrNull { it.isFocused }?.autofillId

        hasActiveRequest = true
        logger.info {
            "Saved AutofillRequest: id=$requestId, selectedEntryId=$entryId, authLevel=$authLevel, pkg=$packageName, domain=$webDomain, " +
                    "originatingPkg=$originatingPackage, users=${usernameFieldIds.size}, pws=${passwordFieldIds.size}, confirmPws=${confirmPwFieldIds.size}, focusedId=$focusedAutofillId"
        }
    }

    fun onClientRequestCancelled(requestId: Int) {
        if (activeRequestId == requestId) {
            logger.info { "Active request $requestId cancelled by client/system (transient resize/relayout)." }
            val listener = onCancelledListener
            listener?.invoke(requestId)
        }
    }

    fun clear() {
        logger.info { "Clearing AutofillRequestStore (wasActive=$hasActiveRequest, id=$activeRequestId)" }
        activeRequestId = null
        selectedEntryId = null
        activeSessionTimestamp = 0L
        pendingAuthLevel = null
        targetPackageName = null
        targetWebDomain = null
        originatingPackageName = null
        focusedAutofillId = null
        usernameFieldIds = emptyList()
        emailFieldIds = emptyList()
        passwordFieldIds = emptyList()
        confirmPwFieldIds = emptyList()
        otpFieldIds = emptyList()
        allFieldIds = emptyList()
        latestStructure = null
        latestParser = null
        hasActiveRequest = false
        fastFillGrants.clear()
    }
}

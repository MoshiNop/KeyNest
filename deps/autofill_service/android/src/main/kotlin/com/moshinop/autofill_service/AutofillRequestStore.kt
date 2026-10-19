package com.moshinop.autofill_service

import android.app.assist.AssistStructure
import android.os.Build
import android.view.autofill.AutofillId
import androidx.annotation.RequiresApi
import mu.KotlinLogging

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
        activeRequestId = requestId
        selectedEntryId = entryId
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
    }
}

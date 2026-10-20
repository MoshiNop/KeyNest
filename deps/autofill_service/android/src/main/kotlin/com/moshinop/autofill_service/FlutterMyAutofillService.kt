package com.moshinop.autofill_service

import android.annotation.TargetApi
import android.app.PendingIntent
import android.app.assist.AssistStructure
import android.content.ComponentName
import android.content.Intent
import android.content.IntentSender
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Shader
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.os.TransactionTooLargeException
import android.service.autofill.*
import android.view.View
import android.view.autofill.AutofillId
import android.view.autofill.AutofillManager
import android.view.autofill.AutofillValue
import android.widget.RemoteViews
import android.widget.Toast
import androidx.annotation.DrawableRes
import androidx.annotation.RequiresApi
import mu.KotlinLogging
import org.json.JSONArray
import org.json.JSONObject

private val logger = KotlinLogging.logger {}

@RequiresApi(api = Build.VERSION_CODES.O)
class FlutterMyAutofillService : AutofillService() {

    companion object {
        var latestStructure: AssistStructure? = null
        var latestParser: AssistStructureParser? = null
    }

    private lateinit var autofillPreferenceStore: AutofillPreferenceStore
    private var unlockLabel = "Autofill with KeyNest"

    override fun onCreate() {
        super.onCreate()
        logger.debug { "Autofill service was created." }
        autofillPreferenceStore = AutofillPreferenceStore.getInstance(applicationContext)
        AutofillServicePluginImpl.cleanupExpiredPendingSaveData(applicationContext)
        AutofillServicePluginImpl.schedulePendingSaveCleanup(applicationContext)
    }

    override fun onConnected() {
        super.onConnected()
        logger.debug("onConnected.")
        val self = ComponentName(this, javaClass)

        try {
            val metaData = packageManager.getServiceInfo(self, PackageManager.GET_META_DATA).metaData
            metaData?.getString("com.moshinop.autofill_service.unlock_label")?.let {
                unlockLabel = it
            }
        } catch (e: Exception) {
            logger.warn(e) { "Could not read service metadata for unlock_label" }
        }
        logger.info("Unlock label will be $unlockLabel")
    }

    override fun onFillRequest(
        request: FillRequest,
        cancellationSignal: CancellationSignal,
        callback: FillCallback
    ) {
        AutofillServicePluginImpl.cleanupExpiredPendingSaveData(applicationContext)
        logger.info { "Got fill request id=${request.id} $request" }

        cancellationSignal.setOnCancelListener {
            logger.info { "FillRequest ${request.id} cancelled by client/system." }
            AutofillRequestStore.onClientRequestCancelled(request.id)
        }

        val contexts = request.fillContexts
        val context = contexts.lastOrNull()
        if (context == null) {
            callback.onSuccess(null)
            return
        }

        // FLAG_VIEW_NOT_FOCUSED (0x10): Check if the request is an unfocused pre-fill / probing request
        // Android 14/15/16 sends pre-fill requests when activities start before any input field is tapped.
        // Returning datasets on an unfocused view creates an unanchored overlay / fill dialog that steals
        // window focus from the target app, causing the soft keyboard to open and immediately close!
        val isViewNotFocused = (request.flags and 0x10) != 0
        if (isViewNotFocused) {
            logger.debug { "FillRequest ${request.id} has FLAG_VIEW_NOT_FOCUSED. Skipping pre-fill to preserve keyboard visibility." }
            callback.onSuccess(null)
            return
        }
        val parser = AssistStructureParser(context.structure)
        latestStructure = context.structure
        latestParser = parser

        val allContextParsers = contexts.map { AssistStructureParser(it.structure) }

        if (parser.autoFillIds.isEmpty() && allContextParsers.all { it.autoFillIds.isEmpty() }) {
            logger.debug { "No autofill IDs detected, skipping fill request." }
            callback.onSuccess(null)
            return
        }

        // Support forms with password, username, email, new password, or OTP/TOTP
        val hasCredentials = allContextParsers.any { p ->
            !p.fieldIds[AutofillInputType.Password].isNullOrEmpty() ||
                    !p.fieldIds[AutofillInputType.NewPassword].isNullOrEmpty() ||
                    !p.fieldIds[AutofillInputType.CurrentPassword].isNullOrEmpty() ||
                    !p.fieldIds[AutofillInputType.UserName].isNullOrEmpty() ||
                    !p.fieldIds[AutofillInputType.Email].isNullOrEmpty() ||
                    !p.fieldIds[AutofillInputType.Otp].isNullOrEmpty()
        }

        if (!hasCredentials) {
            val detectedFields = parser.fieldIds.flatMap { it.value }.size
            logger.debug { "No recognized credential fields ($detectedFields detected)." }
            if (!autofillPreferenceStore.autofillPreferences.enableDebug) {
                callback.onSuccess(null)
                return
            }
        }

        val activityName = try {
            val appInfo = packageManager.getApplicationInfo(packageName, PackageManager.GET_META_DATA)
            appInfo.metaData?.getString("com.moshinop.autofill_service.ACTIVITY_NAME")
                ?: packageManager.getLaunchIntentForPackage(packageName)?.component?.className
                ?: "${packageName}.MainActivity"
        } catch (e: Exception) {
            packageManager.getLaunchIntentForPackage(packageName)?.component?.className
                ?: "${packageName}.MainActivity"
        }
        logger.debug("Resolved activity $activityName for packageName $packageName")

        val startIntent = Intent().apply {
            setClassName(applicationContext, activityName)
            action = Intent.ACTION_RUN
            putExtra("route", "/autofill")
            putExtra("initial_route", "/autofill")
            putExtra("autofillAuthLevel", "response")
            putExtra("autofillRequestId", request.id)
        }

        val originatingPackage = context.structure.activityComponent?.packageName
        if (!originatingPackage.isNullOrBlank()) {
            startIntent.putExtra("originatingPackageName", originatingPackage)
        }

        parser.packageName.firstOrNull()?.let {
            startIntent.putExtra("autofillPackageName", it)
        }
        val primaryDomain = parser.getPrimaryWebDomain()
        if (!primaryDomain.isNullOrBlank()) {
            startIntent.putExtra("autofillWebDomain", primaryDomain)
        }

        startIntent.putExtra(
            AutofillMetadata.EXTRA_NAME,
            AutofillMetadata(parser.packageName, parser.webDomain).toJsonString()
        )
        startIntent.putExtra(AutofillManager.EXTRA_ASSIST_STRUCTURE, context.structure)

        // Separate intent for "Open KeyNest" dataset auth (when matching logins exist)
        val pickerIntent = Intent(startIntent).apply {
            action = "com.moshinop.autofill_service.OPEN_KEYNEST"
            putExtra("forceCredentialPicker", true)
            putExtra("autofillAuthLevel", "dataset")
            putExtra("route", "/autofill")
            putExtra("initial_route", "/autofill")
            putExtra("autofillRequestId", request.id)
        }

        // Separate intent for "Open KeyNest" response-level auth (when zero matching logins exist)
        val responsePickerIntent = Intent(startIntent).apply {
            action = "com.moshinop.autofill_service.OPEN_KEYNEST"
            putExtra("forceCredentialPicker", true)
            putExtra("autofillAuthLevel", "response")
            putExtra("route", "/autofill")
            putExtra("initial_route", "/autofill")
            putExtra("autofillRequestId", request.id)
        }

        val piFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val intentSender: IntentSender = PendingIntent.getActivity(
            this,
            0,
            startIntent,
            piFlags
        ).intentSender

        val pickerSender: IntentSender = PendingIntent.getActivity(
            this,
            1, // request code 1 for dataset picker
            pickerIntent,
            piFlags
        ).intentSender

        val responsePickerSender: IntentSender = PendingIntent.getActivity(
            this,
            2, // request code 2 for response picker
            responsePickerIntent,
            piFlags
        ).intentSender

        val autoFillIds = (parser.autoFillIds + allContextParsers.flatMap { it.autoFillIds }).distinct()
        val targetPackage = parser.getTargetPackage().ifBlank {
            allContextParsers.firstNotNullOfOrNull { it.getTargetPackage().takeIf { p -> p.isNotBlank() } } ?: ""
        }
        val rawDomain = (parser.getPrimaryWebDomain() ?: allContextParsers.firstNotNullOfOrNull { it.getPrimaryWebDomain() }) ?: ""
        val targetDomain = AssistStructureParser.sanitizeWebDomain(rawDomain) ?: ""

        val confirmPwFieldsLatest = parser.fieldIds[AutofillInputType.ConfirmPassword] ?: emptyList()
        val currentPwFieldsLatest = parser.fieldIds[AutofillInputType.CurrentPassword] ?: emptyList()
        val confirmIdsLatest = confirmPwFieldsLatest.map { it.autofillId }.toSet()
        val currentIdsLatest = currentPwFieldsLatest.map { it.autofillId }.toSet()

        val newPwFieldsLatest = (parser.fieldIds[AutofillInputType.NewPassword] ?: emptyList())
            .filter { !confirmIdsLatest.contains(it.autofillId) }
        val newIdsLatest = newPwFieldsLatest.map { it.autofillId }.toSet()

        val standardPwFieldsLatest = (parser.fieldIds[AutofillInputType.Password] ?: emptyList())
            .filter { !confirmIdsLatest.contains(it.autofillId) && !currentIdsLatest.contains(it.autofillId) && !newIdsLatest.contains(it.autofillId) }

        val isPasswordChangeForm = currentPwFieldsLatest.isNotEmpty() && (newPwFieldsLatest.isNotEmpty() || standardPwFieldsLatest.isNotEmpty())

        var passwordFields = if (isPasswordChangeForm) {
            currentPwFieldsLatest
        } else {
            (standardPwFieldsLatest + currentPwFieldsLatest + newPwFieldsLatest)
                .filter { !confirmIdsLatest.contains(it.autofillId) }
                .distinctBy { it.autofillId }
        }
        val newPwFields = (newPwFieldsLatest + allContextParsers.flatMap { ctxP ->
            ctxP.fieldIds[AutofillInputType.NewPassword] ?: emptyList()
        }).distinctBy { it.autofillId }

        val standardPwFields = (standardPwFieldsLatest + allContextParsers.flatMap { ctxP ->
            ctxP.fieldIds[AutofillInputType.Password] ?: emptyList()
        }).distinctBy { it.autofillId }

        var confirmPwFields = confirmPwFieldsLatest
        var currentPwFields = currentPwFieldsLatest
        val detectedEmailFields = parser.fieldIds[AutofillInputType.Email] ?: emptyList()
        val detectedUserFields = parser.fieldIds[AutofillInputType.UserName] ?: emptyList()
        var usernameFields = (detectedUserFields + detectedEmailFields).distinctBy { it.autofillId }
        var otpFields = parser.fieldIds[AutofillInputType.Otp] ?: emptyList()

        // Layout-based inference for custom login forms:
        // If password field is detected but username wasn't recognized by hints/ids,
        // check if there is an editable input preceding the password field in the same view hierarchy.
        if (passwordFields.isNotEmpty() && usernameFields.isEmpty()) {
            val pwNodeId = passwordFields.first().autofillId
            val pwIndex = parser.allNodes.indexOfFirst { it.autofillId == pwNodeId }
            if (pwIndex > 0) {
                val candidateNode = parser.allNodes
                    .subList(0, pwIndex)
                    .lastOrNull { node ->
                        val id = node.autofillId
                        id != null &&
                                node.visibility == View.VISIBLE &&
                                (node.autofillType == View.AUTOFILL_TYPE_TEXT ||
                                        node.inputType != 0 ||
                                        node.className?.contains("Edit", ignoreCase = true) == true) &&
                                passwordFields.none { it.autofillId == id } &&
                                confirmPwFields.none { it.autofillId == id } &&
                                otpFields.none { it.autofillId == id }
                    }
                if (candidateNode != null && candidateNode.autofillId != null) {
                    val inferred = MatchedField(
                        AutofillHeuristic(350, "inferred-preceding-username") { true },
                        candidateNode.autofillId!!
                    )
                    usernameFields = listOf(inferred)
                    parser.fieldIds.getOrPut(AutofillInputType.UserName) { mutableListOf() }.add(inferred)
                }
            }
        }

        // Check whether this active session contained a combined login form with both username and password
        val sessionHadCombinedForm = allContextParsers.any { ctxP ->
            val ctxUsers = (ctxP.fieldIds[AutofillInputType.UserName] ?: emptyList()) +
                    (ctxP.fieldIds[AutofillInputType.Email] ?: emptyList())
            val ctxPws = (ctxP.fieldIds[AutofillInputType.Password] ?: emptyList()) +
                    (ctxP.fieldIds[AutofillInputType.NewPassword] ?: emptyList()) +
                    (ctxP.fieldIds[AutofillInputType.CurrentPassword] ?: emptyList())
            ctxUsers.isNotEmpty() && ctxPws.isNotEmpty()
        } || (AutofillRequestStore.hasActiveRequest &&
                AutofillRequestStore.targetPackageName == targetPackage &&
                (targetDomain.isBlank() || AutofillRequestStore.targetWebDomain == targetDomain) &&
                AutofillRequestStore.usernameFieldIds.isNotEmpty() &&
                AutofillRequestStore.passwordFieldIds.isNotEmpty())

        if (sessionHadCombinedForm) {
            // Aggregate all associated login fields discovered across this session
            val aggregatedPws = (passwordFields + allContextParsers.flatMap { ctxP ->
                val cIds = (ctxP.fieldIds[AutofillInputType.ConfirmPassword] ?: emptyList()).map { it.autofillId }.toSet()
                ((ctxP.fieldIds[AutofillInputType.Password] ?: emptyList()) +
                        (ctxP.fieldIds[AutofillInputType.NewPassword] ?: emptyList()) +
                        (ctxP.fieldIds[AutofillInputType.CurrentPassword] ?: emptyList())).filter { !cIds.contains(it.autofillId) }
            }).distinctBy { it.autofillId }.toMutableList()

            if (AutofillRequestStore.hasActiveRequest &&
                AutofillRequestStore.targetPackageName == targetPackage &&
                (targetDomain.isBlank() || AutofillRequestStore.targetWebDomain == targetDomain)) {
                for (storePwId in AutofillRequestStore.passwordFieldIds) {
                    if (aggregatedPws.none { it.autofillId == storePwId }) {
                        aggregatedPws.add(MatchedField(AutofillHeuristic(300, "session-restored-password") { true }, storePwId))
                    }
                }
            }
            passwordFields = aggregatedPws

            val aggregatedUsers = (usernameFields + allContextParsers.flatMap { ctxP ->
                (ctxP.fieldIds[AutofillInputType.UserName] ?: emptyList()) +
                        (ctxP.fieldIds[AutofillInputType.Email] ?: emptyList())
            }).distinctBy { it.autofillId }.toMutableList()

            if (AutofillRequestStore.hasActiveRequest &&
                AutofillRequestStore.targetPackageName == targetPackage &&
                (targetDomain.isBlank() || AutofillRequestStore.targetWebDomain == targetDomain)) {
                for (storeUserId in (AutofillRequestStore.usernameFieldIds + AutofillRequestStore.emailFieldIds)) {
                    if (aggregatedUsers.none { it.autofillId == storeUserId }) {
                        aggregatedUsers.add(MatchedField(AutofillHeuristic(300, "session-restored-username") { true }, storeUserId))
                    }
                }
            }
            usernameFields = aggregatedUsers

            val aggregatedConfirmPws = (confirmPwFields + allContextParsers.flatMap { ctxP ->
                ctxP.fieldIds[AutofillInputType.ConfirmPassword] ?: emptyList()
            }).distinctBy { it.autofillId }.toMutableList()

            if (AutofillRequestStore.hasActiveRequest &&
                AutofillRequestStore.targetPackageName == targetPackage &&
                (targetDomain.isBlank() || AutofillRequestStore.targetWebDomain == targetDomain)) {
                for (storeConfirmId in AutofillRequestStore.confirmPwFieldIds) {
                    if (aggregatedConfirmPws.none { it.autofillId == storeConfirmId }) {
                        aggregatedConfirmPws.add(MatchedField(AutofillHeuristic(300, "session-restored-confirm") { true }, storeConfirmId))
                    }
                }
            }
            confirmPwFields = aggregatedConfirmPws

            val aggregatedOtps = (otpFields + allContextParsers.flatMap { ctxP ->
                ctxP.fieldIds[AutofillInputType.Otp] ?: emptyList()
            }).distinctBy { it.autofillId }
            otpFields = aggregatedOtps
        }

        val fillResponseBuilder = FillResponse.Builder()

        val contextKey = if (targetDomain.isNotEmpty()) targetDomain else targetPackage

        // Inspect fillEventHistory to see if a dataset was selected in the preceding step
        try {
            val history = fillEventHistory
            val events = history?.events
            val lastSelectedEvent = events?.lastOrNull {
                it.type == android.service.autofill.FillEventHistory.Event.TYPE_DATASET_SELECTED
            }
            val selectedDatasetId = lastSelectedEvent?.datasetId
            if (!selectedDatasetId.isNullOrBlank()) {
                val baseId = selectedDatasetId.substringBefore(":")
                val allEntries = AutofillCredentialStore.getEntries().ifEmpty {
                    AutofillCredentialStore.getMetadataEntries()
                }
                val selectedEntry = allEntries.firstOrNull { it.id == baseId }
                if (selectedEntry != null) {
                    val identifier = if (selectedDatasetId.endsWith(":email") && !selectedEntry.email.isNullOrBlank()) {
                        selectedEntry.email!!
                    } else {
                        selectedEntry.username.ifBlank { selectedEntry.email ?: "" }
                    }
                    AutofillCredentialStore.rememberPendingLogin(selectedEntry.id, contextKey, identifier)
                }
            }
        } catch (e: Exception) {
            logger.debug { "Could not inspect fillEventHistory: $e" }
        }

        // Multi-page Step 1: record username entered/autofilled for multi-page correlation
        // Only treat as username-first step if there are no password or OTP fields present
        if (passwordFields.isEmpty() && usernameFields.isNotEmpty() && otpFields.isEmpty()) {
            val typedUser = usernameFields.mapNotNull { field ->
                val node = parser.allNodes.firstOrNull { it.autofillId == field.autofillId }
                node?.autofillValue?.textValue?.toString()?.takeIf { it.isNotBlank() }
                    ?: node?.text?.toString()?.takeIf { it.isNotBlank() }
            }.firstOrNull() ?: ""
            if (typedUser.isNotBlank()) {
                AutofillCredentialStore.recordSessionUsername(contextKey, typedUser)
                val existing = AutofillCredentialStore.getValidPendingLogin(contextKey)
                if (existing != null && !existing.username.equals(typedUser, ignoreCase = true)) {
                    AutofillCredentialStore.clearPendingLogin()
                }
            } else {
                // Fresh username-first screen with empty input: clear stale pending login from previous session
                AutofillCredentialStore.clearPendingLogin()
            }
        }
        val focusedNode = parser.allNodes.firstOrNull { it.isFocused }
        val focusedAutofillId = focusedNode?.autofillId

        val isExplicitEmailField = focusedNode != null && (
            (detectedEmailFields.any { it.autofillId == focusedAutofillId }) ||
            (focusedNode.autofillHints?.any { it.contains("email", ignoreCase = true) || it.contains("mail", ignoreCase = true) } == true) ||
            (focusedNode.htmlInfo?.attributes?.any { it.first.equals("type", ignoreCase = true) && it.second.equals("email", ignoreCase = true) } == true) ||
            ((focusedNode.inputType and android.text.InputType.TYPE_MASK_VARIATION) == android.text.InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS) ||
            ((focusedNode.inputType and android.text.InputType.TYPE_MASK_VARIATION) == android.text.InputType.TYPE_TEXT_VARIATION_WEB_EMAIL_ADDRESS) ||
            (focusedNode.idEntry?.contains("email", ignoreCase = true) == true || focusedNode.idEntry?.contains("mail", ignoreCase = true) == true) ||
            (focusedNode.hint?.contains("email", ignoreCase = true) == true || focusedNode.hint?.contains("mail", ignoreCase = true) == true)
        )

        val isExplicitUsernameField = focusedNode != null && !isExplicitEmailField && (
            (detectedUserFields.any { it.autofillId == focusedAutofillId }) ||
            (focusedNode.autofillHints?.any { it.contains("username", ignoreCase = true) || it.contains("user", ignoreCase = true) } == true) ||
            (focusedNode.idEntry?.contains("username", ignoreCase = true) == true || focusedNode.idEntry?.contains("user", ignoreCase = true) == true) ||
            (focusedNode.hint?.contains("username", ignoreCase = true) == true || focusedNode.hint?.contains("user", ignoreCase = true) == true)
        )

        val isOtpFocused = focusedNode != null && otpFields.any { it.autofillId == focusedAutofillId }

        val currentScreenHasOtp = parser.fieldIds[AutofillInputType.Otp]?.isNotEmpty() == true
        val currentScreenHasUser = parser.fieldIds[AutofillInputType.UserName]?.isNotEmpty() == true ||
            parser.fieldIds[AutofillInputType.Email]?.isNotEmpty() == true
        val currentScreenHasPassword = parser.fieldIds[AutofillInputType.Password]?.isNotEmpty() == true ||
            parser.fieldIds[AutofillInputType.NewPassword]?.isNotEmpty() == true ||
            parser.fieldIds[AutofillInputType.CurrentPassword]?.isNotEmpty() == true

        val isOtpOnlyScreen = (otpFields.isNotEmpty() && passwordFields.isEmpty() && usernameFields.isEmpty()) ||
            (currentScreenHasOtp && !currentScreenHasUser && !currentScreenHasPassword)
        val isTotpVerification = isOtpOnlyScreen || (isOtpFocused && otpFields.isNotEmpty())

        val targetFormIds = (usernameFields.map { it.autofillId } +
                passwordFields.map { it.autofillId } +
                currentPwFields.map { it.autofillId } +
                confirmPwFields.map { it.autofillId } +
                otpFields.map { it.autofillId }).distinct()
        val candidateInputIds = parser.allNodes
            .filter { it.isFocused || it.autofillType == View.AUTOFILL_TYPE_TEXT || it.inputType != 0 || it.className?.contains("Edit", ignoreCase = true) == true }
            .mapNotNull { it.autofillId }
            .distinct()
        val authIds: List<AutofillId> = if (targetFormIds.isNotEmpty()) {
            targetFormIds
        } else if (focusedNode?.autofillId != null) {
            listOf(focusedNode.autofillId!!)
        } else if (candidateInputIds.isNotEmpty()) {
            candidateInputIds.take(3)
        } else {
            autoFillIds.take(3)
        }
        val orderedAuthIds = if (focusedAutofillId != null && authIds.contains(focusedAutofillId)) {
            listOf(focusedAutofillId) + authIds.filter { it != focusedAutofillId }
        } else {
            authIds
        }

        // Check whether vault is locked (including auto-lock timeout expiration)
        AutofillCredentialStore.loadMetadata(applicationContext)
        if (AutofillCredentialStore.isAutoLockExpired()) {
            AutofillCredentialStore.clear()
        }
        if (AutofillCredentialStore.isLocked) {
            AutofillRequestStore.saveRequest(
                authLevel = "dataset",
                packageName = targetPackage,
                webDomain = targetDomain,
                structure = context.structure,
                parser = parser,
                requestId = request.id,
                originatingPackage = originatingPackage,
                overrideUsernameIds = (parser.fieldIds[AutofillInputType.UserName]?.map { it.autofillId } ?: emptyList()).distinct(),
                overrideEmailIds = (parser.fieldIds[AutofillInputType.Email]?.map { it.autofillId } ?: emptyList()).distinct(),
                overridePasswordIds = passwordFields.map { it.autofillId }.distinct(),
                overrideConfirmPwIds = confirmPwFields.map { it.autofillId }.distinct(),
                overrideOtpIds = otpFields.map { it.autofillId }.distinct()
            )

            if (isTotpVerification) {
                // 2FA Verification page while locked:
                val pendingLogin = AutofillCredentialStore.getValidPendingLogin(contextKey)
                val lockedMatches = AutofillCredentialStore.findMatches(targetPackage, targetDomain).toMutableList()
                val exactEntry = if (pendingLogin != null) {
                    AutofillCredentialStore.getMetadataEntries().firstOrNull { it.id == pendingLogin.entryId }
                        ?: lockedMatches.firstOrNull { it.id == pendingLogin.entryId }
                } else null

                val entriesToSuggest = if (exactEntry != null && exactEntry.hasTotp) {
                    // Prioritize and ONLY suggest the previously selected entry
                    listOf(exactEntry)
                } else {
                    // Fallback (if exactEntry has no TOTP secret, or if pendingLogin is null):
                    // Gracefully fallback / preserve existing behavior by suggesting matching entries with TOTP
                    val totpMatches = lockedMatches.filter { it.hasTotp }
                    if (totpMatches.isNotEmpty()) totpMatches else lockedMatches
                }

                var totpIntentCodeCounter = 2000
                for (entry in entriesToSuggest) {
                    val subtitleText = if (entry.username.isNotBlank()) {
                        "${entry.label} (${entry.username}) • Tap to unlock"
                    } else {
                        "${entry.label} • Tap to unlock"
                    }
                    val presentation = RemoteViewsHelper.viewsWithTotp(
                        packageName = packageName,
                        title = "Verification code",
                        subtitle = subtitleText,
                        iconBytes = entry.iconBytes,
                        isLocked = true
                    )
                    val entryIntent = Intent(startIntent).apply {
                        action = "com.moshinop.autofill_service.FILL_ENTRY"
                        putExtra("selectedEntryId", entry.id)
                        putExtra("isTotp", true)
                        putExtra("forceCredentialPicker", false)
                        putExtra("autofillAuthLevel", "dataset")
                        putExtra("route", "/autofill")
                        putExtra("initial_route", "/autofill")
                        putExtra("autofillRequestId", request.id)
                    }
                    val entrySender: IntentSender = PendingIntent.getActivity(
                        this,
                        totpIntentCodeCounter++,
                        entryIntent,
                        piFlags
                    ).intentSender

                    val datasetBuilder = Dataset.Builder(presentation)
                        .setAuthentication(entrySender)
                        .setId(entry.id)
                    for (field in otpFields) {
                        datasetBuilder.setValue(field.autofillId, null, presentation)
                    }
                    fillResponseBuilder.addDataset(datasetBuilder.build())
                }
            } else {
                // Standard locked credential page:
                val lockedMatches = AutofillCredentialStore.findMatches(targetPackage, targetDomain).toMutableList()
                val isPasswordOnlyScreen = passwordFields.isNotEmpty() && usernameFields.isEmpty()

                if (isPasswordOnlyScreen && lockedMatches.isNotEmpty()) {
                    val pendingLogin = AutofillCredentialStore.getValidPendingLogin(contextKey)
                    val sessionUser = AutofillCredentialStore.getSessionUsername(contextKey)

                    var prioritizedEntry: NativeAutofillEntry? = null

                    // 1. Exact stable entry ID from previous selection
                    if (pendingLogin != null && pendingLogin.entryId.isNotBlank()) {
                        prioritizedEntry = lockedMatches.firstOrNull { it.id == pendingLogin.entryId }
                    }

                    // 2. Username correlation strictly within current website matches
                    if (prioritizedEntry == null) {
                        val targetUser = when {
                            pendingLogin != null && pendingLogin.username.isNotBlank() -> pendingLogin.username.trim()
                            !sessionUser.isNullOrBlank() -> sessionUser.trim()
                            else -> ""
                        }
                        if (targetUser.isNotBlank()) {
                            prioritizedEntry = lockedMatches.firstOrNull { entry ->
                                (entry.username.isNotBlank() && entry.username.trim().equals(targetUser, ignoreCase = true)) ||
                                (!entry.email.isNullOrBlank() && entry.email.trim().equals(targetUser, ignoreCase = true))
                            }
                        }
                    }

                    // 3. Visible screen text correlation strictly within current website matches
                    if (prioritizedEntry == null) {
                        val visibleTexts = parser.allNodes
                            .mapNotNull { it.text?.toString()?.trim()?.lowercase() }
                            .filter { it.isNotBlank() }

                        if (visibleTexts.isNotEmpty()) {
                            prioritizedEntry = lockedMatches.firstOrNull { entry ->
                                (entry.username.isNotBlank() && visibleTexts.any { vt ->
                                    vt == entry.username.lowercase() || vt.contains(entry.username.lowercase())
                                }) ||
                                (!entry.email.isNullOrBlank() && visibleTexts.any { vt ->
                                    vt == entry.email.lowercase() || vt.contains(entry.email.lowercase())
                                })
                            }
                        }
                    }

                    val prioritized = prioritizedEntry
                    if (prioritized != null) {
                        lockedMatches.removeIf { it.id == prioritized.id }
                        lockedMatches.add(0, prioritized)
                        AutofillCredentialStore.rememberPendingLogin(prioritized.id, contextKey, prioritized.username)
                    }
                }

                if (lockedMatches.isNotEmpty()) {
                    var intentCodeCounter = 1000
                    for (entry in lockedMatches.take(20)) {
                        val hasUser = entry.username.isNotBlank()
                        val hasMail = !entry.email.isNullOrBlank() && !entry.email.equals(entry.username, ignoreCase = true)

                        if (hasUser && hasMail) {
                            fun addLockedSuggestion(identifierVal: String, identifierType: String) {
                                val presentation = RemoteViewsHelper.viewsWithCredential(
                                    packageName = packageName,
                                    title = entry.label,
                                    subtitle = identifierVal,
                                    iconBytes = entry.iconBytes,
                                    isLocked = true
                                )
                                val entryIntent = Intent(startIntent).apply {
                                    action = "com.moshinop.autofill_service.FILL_ENTRY"
                                    putExtra("selectedEntryId", entry.id)
                                    putExtra("fillIdentifier", identifierType)
                                    putExtra("selectedIdentifier", identifierVal)
                                    putExtra("forceCredentialPicker", false)
                                    putExtra("autofillAuthLevel", "dataset")
                                    putExtra("route", "/autofill")
                                    putExtra("initial_route", "/autofill")
                                    putExtra("autofillRequestId", request.id)
                                }
                                val entrySender: IntentSender = PendingIntent.getActivity(
                                    this,
                                    intentCodeCounter++,
                                    entryIntent,
                                    piFlags
                                ).intentSender

                                val datasetBuilder = Dataset.Builder(presentation)
                                    .setAuthentication(entrySender)
                                    .setId("${entry.id}:$identifierType")
                                for (targetId in orderedAuthIds) {
                                    datasetBuilder.setValue(
                                        targetId,
                                        null,
                                        presentation
                                    )
                                }
                                fillResponseBuilder.addDataset(datasetBuilder.build())
                            }

                            if (isExplicitEmailField) {
                                addLockedSuggestion(entry.email!!, "email")
                                addLockedSuggestion(entry.username, "username")
                            } else {
                                addLockedSuggestion(entry.username, "username")
                                addLockedSuggestion(entry.email!!, "email")
                            }
                        } else {
                            val subtitle = if (hasUser) entry.username else (entry.email ?: "").ifBlank { null }
                            val identifierType = if (hasUser) "username" else "email"
                            val presentation = RemoteViewsHelper.viewsWithCredential(
                                packageName = packageName,
                                title = entry.label,
                                subtitle = subtitle,
                                iconBytes = entry.iconBytes,
                                isLocked = true
                            )
                            val entryIntent = Intent(startIntent).apply {
                                action = "com.moshinop.autofill_service.FILL_ENTRY"
                                putExtra("selectedEntryId", entry.id)
                                putExtra("fillIdentifier", identifierType)
                                putExtra("selectedIdentifier", subtitle ?: "")
                                putExtra("forceCredentialPicker", false)
                                putExtra("autofillAuthLevel", "dataset")
                                putExtra("route", "/autofill")
                                putExtra("initial_route", "/autofill")
                                putExtra("autofillRequestId", request.id)
                            }
                            val entrySender: IntentSender = PendingIntent.getActivity(
                                this,
                                intentCodeCounter++,
                                entryIntent,
                                piFlags
                            ).intentSender

                            val datasetBuilder = Dataset.Builder(presentation)
                                .setAuthentication(entrySender)
                                .setId(entry.id)
                            for (targetId in orderedAuthIds) {
                                datasetBuilder.setValue(
                                    targetId,
                                    null,
                                    presentation
                                )
                            }
                            fillResponseBuilder.addDataset(datasetBuilder.build())
                        }
                    }
                }
            }

            // In all locked situations: "Open KeyNest" is appended at the bottom
            try {
                val searchPresentation = RemoteViewsHelper.viewsWithSearch(packageName, "Open KeyNest", "Search or select saved logins")
                val searchDatasetBuilder = Dataset.Builder(searchPresentation)
                    .setAuthentication(pickerSender)
                for (targetId in orderedAuthIds) {
                    searchDatasetBuilder.setValue(
                        targetId,
                        null,
                        searchPresentation
                    )
                }
                fillResponseBuilder.addDataset(searchDatasetBuilder.build())
            } catch (e: Exception) {
                logger.error(e) { "Could not add Open KeyNest dataset when locked: $e" }
            }
        } else {
            // Unlocked: find matching entries from in-memory credential store
            AutofillCredentialStore.touchActive()
            val matches = AutofillCredentialStore.findMatches(targetPackage, targetDomain).toMutableList()

            val pendingLogin = AutofillCredentialStore.getValidPendingLogin(contextKey)

            if (isTotpVerification) {
                // 2FA Verification page while unlocked:
                fun addTotpDataset(entry: NativeAutofillEntry) {
                    if (!entry.hasTotp) return
                    val secret = entry.otpSecret ?: entry.otp ?: return
                    val liveCode = KeyNestTotp.generateTotp(
                        secretBase32 = secret,
                        algorithm = entry.otpAlgorithm,
                        period = entry.otpPeriod,
                        digits = entry.otpDigits
                    )
                    if (liveCode.isBlank()) return
                    val displayCode = KeyNestTotp.formatDisplayCode(liveCode)
                    val subtitleText = if (entry.username.isNotBlank()) {
                        "${entry.label} (${entry.username}) • 2FA Code"
                    } else {
                        "${entry.label} • 2FA Code"
                    }
                    val presentation = RemoteViewsHelper.viewsWithTotp(
                        packageName = packageName,
                        title = displayCode,
                        subtitle = subtitleText,
                        iconBytes = entry.iconBytes,
                        isLocked = false
                    )
                    val datasetBuilder = Dataset.Builder(presentation)
                    datasetBuilder.setId(entry.id)

                    val filledIds = mutableSetOf<AutofillId>()
                    val distinctOtpFields = otpFields.distinctBy { it.autofillId }

                    if (distinctOtpFields.size == liveCode.length) {
                        // Multi-field verification inputs (e.g. 6 separate single-digit boxes)
                        distinctOtpFields.forEachIndexed { i, field ->
                            if (filledIds.add(field.autofillId)) {
                                datasetBuilder.setValue(
                                    field.autofillId,
                                    AutofillValue.forText(liveCode[i].toString()),
                                    presentation
                                )
                            }
                        }
                    } else {
                        // Single-field OTP input
                        distinctOtpFields.forEach { field ->
                            if (filledIds.add(field.autofillId)) {
                                datasetBuilder.setValue(
                                    field.autofillId,
                                    AutofillValue.forText(liveCode),
                                    presentation
                                )
                            }
                        }
                    }

                    fillResponseBuilder.addDataset(datasetBuilder.build())
                }

                val exactEntry = if (pendingLogin != null) {
                    AutofillCredentialStore.getEntries().firstOrNull { it.id == pendingLogin.entryId }
                        ?: matches.firstOrNull { it.id == pendingLogin.entryId }
                } else null

                if (exactEntry != null && exactEntry.hasTotp) {
                    // Prioritize and ONLY suggest the previously selected entry
                    addTotpDataset(exactEntry)
                } else {
                    // Fallback (if exactEntry has no TOTP secret, or if pendingLogin is null):
                    // Gracefully fallback / preserve existing behavior by suggesting matching entries with TOTP
                    for (entry in matches.filter { it.hasTotp }) {
                        addTotpDataset(entry)
                    }
                }
            } else {
                // Standard credential autofill (login, password, registration, etc.):
                val isPasswordOnlyScreen = passwordFields.isNotEmpty() && usernameFields.isEmpty()

                if (isPasswordOnlyScreen) {
                    val sessionUser = AutofillCredentialStore.getSessionUsername(contextKey)

                    // Prioritize the correct credential for THIS website origin using multiple reliable signals:
                    var prioritizedEntry: NativeAutofillEntry? = null

                    // 1. Exact stable entry ID from the selection made on the previous step
                    if (pendingLogin != null && pendingLogin.entryId.isNotBlank()) {
                        prioritizedEntry = matches.firstOrNull { it.id == pendingLogin.entryId }
                    }

                    // 2. Fallback to username matching strictly within this website's matches
                    if (prioritizedEntry == null) {
                        val targetUser = when {
                            pendingLogin != null && pendingLogin.username.isNotBlank() -> pendingLogin.username.trim()
                            !sessionUser.isNullOrBlank() -> sessionUser.trim()
                            else -> ""
                        }
                        if (targetUser.isNotBlank()) {
                            prioritizedEntry = matches.firstOrNull { entry ->
                                (entry.username.isNotBlank() && entry.username.trim().equals(targetUser, ignoreCase = true)) ||
                                (!entry.email.isNullOrBlank() && entry.email.trim().equals(targetUser, ignoreCase = true))
                            }
                        }
                    }

                    // 3. Screen text correlation strictly within this website's matches
                    if (prioritizedEntry == null) {
                        val visibleTexts = parser.allNodes
                            .mapNotNull { it.text?.toString()?.trim()?.lowercase() }
                            .filter { it.isNotBlank() }

                        if (visibleTexts.isNotEmpty()) {
                            prioritizedEntry = matches.firstOrNull { entry ->
                                (entry.username.isNotBlank() && visibleTexts.any { vt ->
                                    vt == entry.username.lowercase() || vt.contains(entry.username.lowercase())
                                }) ||
                                (!entry.email.isNullOrBlank() && visibleTexts.any { vt ->
                                    vt == entry.email.lowercase() || vt.contains(entry.email.lowercase())
                                })
                            }
                        }
                    }

                    // Prioritize at the top of matches
                    if (prioritizedEntry != null) {
                        matches.removeIf { it.id == prioritizedEntry.id }
                        matches.add(0, prioritizedEntry)
                        AutofillCredentialStore.rememberPendingLogin(prioritizedEntry.id, contextKey, prioritizedEntry.username)
                    }
                }

                if (matches.isNotEmpty()) {
                    val detectedEmail = parser.fieldIds[AutofillInputType.Email] ?: emptyList()
                    val detectedUser = parser.fieldIds[AutofillInputType.UserName] ?: emptyList()
                    val dedicatedEmailFields = detectedEmail.filter { ef -> detectedUser.none { uf -> uf.autofillId == ef.autofillId } }
                    val dedicatedUserFields = detectedUser.filter { uf -> detectedEmail.none { ef -> ef.autofillId == uf.autofillId } }
                    val sharedLoginFields = usernameFields.filter { lf ->
                        dedicatedEmailFields.none { it.autofillId == lf.autofillId } &&
                        dedicatedUserFields.none { it.autofillId == lf.autofillId }
                    }

                    for (entry in matches.take(20)) {
                        val hasUser = entry.username.isNotBlank()
                        val hasMail = !entry.email.isNullOrBlank() && !entry.email.equals(entry.username, ignoreCase = true)

                        fun buildUnlockedDataset(
                            identifierVal: String,
                            identifierType: String,
                            datasetId: String
                        ): Dataset {
                            val presentation = RemoteViewsHelper.viewsWithCredential(
                                packageName = packageName,
                                title = entry.label,
                                subtitle = identifierVal.ifBlank { null },
                                iconBytes = entry.iconBytes,
                                isLocked = false
                            )
                            val datasetBuilder = Dataset.Builder(presentation)
                            datasetBuilder.setId(datasetId)

                            val filledIds = mutableSetOf<AutofillId>()

                            // 0. Primary Anchor: If a field is currently focused, bind it FIRST so Android anchors the dataset directly to the active input
                            if (focusedAutofillId != null) {
                                val isFocusedUser = usernameFields.any { it.autofillId == focusedAutofillId }
                                val isFocusedPw = passwordFields.any { it.autofillId == focusedAutofillId }
                                val isFocusedConfirm = confirmPwFields.any { it.autofillId == focusedAutofillId }
                                val isFocusedOtp = otpFields.any { it.autofillId == focusedAutofillId }

                                if (isFocusedUser && filledIds.add(focusedAutofillId)) {
                                    val focusPresentation = RemoteViewsHelper.viewsWithCredential(
                                        packageName = packageName,
                                        title = entry.label,
                                        subtitle = identifierVal,
                                        iconBytes = entry.iconBytes,
                                        isLocked = false
                                    )
                                    datasetBuilder.setValue(
                                        focusedAutofillId,
                                        AutofillValue.forText(identifierVal),
                                        focusPresentation
                                    )
                                } else if (isFocusedPw && filledIds.add(focusedAutofillId)) {
                                    val focusPresentation = RemoteViewsHelper.viewsWithCredential(
                                        packageName = packageName,
                                        title = entry.label,
                                        subtitle = if (identifierVal.isNotBlank()) identifierVal else "Password",
                                        iconBytes = entry.iconBytes,
                                        isLocked = false
                                    )
                                    datasetBuilder.setValue(
                                        focusedAutofillId,
                                        AutofillValue.forText(entry.password),
                                        focusPresentation
                                    )
                                } else if (isFocusedConfirm && filledIds.add(focusedAutofillId)) {
                                    val focusPresentation = RemoteViewsHelper.viewsWithCredential(
                                        packageName = packageName,
                                        title = entry.label,
                                        subtitle = "Confirm Password",
                                        iconBytes = entry.iconBytes,
                                        isLocked = false
                                    )
                                    datasetBuilder.setValue(
                                        focusedAutofillId,
                                        AutofillValue.forText(entry.password),
                                        focusPresentation
                                    )
                                } else if (isFocusedOtp && entry.hasTotp && filledIds.add(focusedAutofillId)) {
                                    val secret = entry.otpSecret ?: entry.otp
                                    val liveCode = KeyNestTotp.generateTotp(
                                        secretBase32 = secret,
                                        algorithm = entry.otpAlgorithm,
                                        period = entry.otpPeriod,
                                        digits = entry.otpDigits
                                    )
                                    if (liveCode.isNotBlank()) {
                                        val focusPresentation = RemoteViewsHelper.viewsWithTotp(
                                            packageName = packageName,
                                            title = KeyNestTotp.formatDisplayCode(liveCode),
                                            subtitle = "${entry.label} ($identifierVal) • 2FA Code",
                                            iconBytes = entry.iconBytes,
                                            isLocked = false
                                        )
                                        datasetBuilder.setValue(
                                            focusedAutofillId,
                                            AutofillValue.forText(liveCode),
                                            focusPresentation
                                        )
                                    }
                                }
                            }

                            // 1. Password fields
                            passwordFields.forEach { field ->
                                if (filledIds.add(field.autofillId)) {
                                    val pwPresentation = RemoteViewsHelper.viewsWithCredential(
                                        packageName = packageName,
                                        title = entry.label,
                                        subtitle = if (identifierVal.isNotBlank()) identifierVal else "Password",
                                        iconBytes = entry.iconBytes,
                                        isLocked = false
                                    )
                                    datasetBuilder.setValue(
                                        field.autofillId,
                                        AutofillValue.forText(entry.password),
                                        pwPresentation
                                    )
                                }
                            }

                            // 1b. Confirm password fields (autofills matching password on registration/signup forms)
                            confirmPwFields.forEach { field ->
                                if (filledIds.add(field.autofillId)) {
                                    val pwPresentation = RemoteViewsHelper.viewsWithCredential(
                                        packageName = packageName,
                                        title = entry.label,
                                        subtitle = "Confirm Password",
                                        iconBytes = entry.iconBytes,
                                        isLocked = false
                                    )
                                    datasetBuilder.setValue(
                                        field.autofillId,
                                        AutofillValue.forText(entry.password),
                                        pwPresentation
                                    )
                                }
                            }

                            // 2. Login fields
                            val emailValue = entry.email?.takeIf { it.isNotBlank() } ?: entry.username
                            val userValue = entry.username.ifBlank { entry.email ?: "" }

                            // If focused on an explicit login field, ensure the focused field receives this suggestion's identifier
                            if (focusedAutofillId != null && usernameFields.any { it.autofillId == focusedAutofillId }) {
                                if (filledIds.add(focusedAutofillId)) {
                                    val focusPresentation = RemoteViewsHelper.viewsWithCredential(
                                        packageName = packageName,
                                        title = entry.label,
                                        subtitle = identifierVal,
                                        iconBytes = entry.iconBytes,
                                        isLocked = false
                                    )
                                    datasetBuilder.setValue(
                                        focusedAutofillId,
                                        AutofillValue.forText(identifierVal),
                                        focusPresentation
                                    )
                                }
                            }

                            // Dedicated email fields
                            dedicatedEmailFields.forEach { field ->
                                if (filledIds.add(field.autofillId)) {
                                    val valToFill = if (identifierType == "username" && dedicatedUserFields.isEmpty()) {
                                        identifierVal
                                    } else {
                                        emailValue
                                    }
                                    val fieldPresentation = RemoteViewsHelper.viewsWithCredential(
                                        packageName = packageName,
                                        title = entry.label,
                                        subtitle = valToFill,
                                        iconBytes = entry.iconBytes,
                                        isLocked = false
                                    )
                                    datasetBuilder.setValue(
                                        field.autofillId,
                                        AutofillValue.forText(valToFill),
                                        fieldPresentation
                                    )
                                }
                            }

                            // Dedicated username fields
                            dedicatedUserFields.forEach { field ->
                                if (filledIds.add(field.autofillId)) {
                                    val valToFill = if (identifierType == "email" && dedicatedEmailFields.isEmpty()) {
                                        identifierVal
                                    } else {
                                        userValue
                                    }
                                    val fieldPresentation = RemoteViewsHelper.viewsWithCredential(
                                        packageName = packageName,
                                        title = entry.label,
                                        subtitle = valToFill,
                                        iconBytes = entry.iconBytes,
                                        isLocked = false
                                    )
                                    datasetBuilder.setValue(
                                        field.autofillId,
                                        AutofillValue.forText(valToFill),
                                        fieldPresentation
                                    )
                                }
                            }

                            // Shared / generic login fields
                            sharedLoginFields.forEach { field ->
                                if (filledIds.add(field.autofillId)) {
                                    val fieldPresentation = RemoteViewsHelper.viewsWithCredential(
                                        packageName = packageName,
                                        title = entry.label,
                                        subtitle = identifierVal,
                                        iconBytes = entry.iconBytes,
                                        isLocked = false
                                    )
                                    datasetBuilder.setValue(
                                        field.autofillId,
                                        AutofillValue.forText(identifierVal),
                                        fieldPresentation
                                    )
                                }
                            }

                            // 3. OTP fields on combo forms (only when entry has TOTP configured)
                            if (entry.hasTotp) {
                                val secret = entry.otpSecret ?: entry.otp
                                val liveCode = KeyNestTotp.generateTotp(
                                    secretBase32 = secret,
                                    algorithm = entry.otpAlgorithm,
                                    period = entry.otpPeriod,
                                    digits = entry.otpDigits
                                )
                                if (liveCode.isNotBlank()) {
                                    otpFields.forEach { field ->
                                        if (filledIds.add(field.autofillId)) {
                                            val otpPresentation = RemoteViewsHelper.viewsWithTotp(
                                                packageName = packageName,
                                                title = KeyNestTotp.formatDisplayCode(liveCode),
                                                subtitle = "${entry.label} ($identifierVal) • 2FA Code",
                                                iconBytes = entry.iconBytes,
                                                isLocked = false
                                            )
                                            datasetBuilder.setValue(
                                                field.autofillId,
                                                AutofillValue.forText(liveCode),
                                                otpPresentation
                                            )
                                        }
                                    }
                                }
                            }

                            return datasetBuilder.build()
                        }

                        if (hasUser && hasMail) {
                            if (isExplicitEmailField) {
                                fillResponseBuilder.addDataset(buildUnlockedDataset(entry.email!!, "email", "${entry.id}:email"))
                                fillResponseBuilder.addDataset(buildUnlockedDataset(entry.username, "username", "${entry.id}:username"))
                            } else {
                                fillResponseBuilder.addDataset(buildUnlockedDataset(entry.username, "username", "${entry.id}:username"))
                                fillResponseBuilder.addDataset(buildUnlockedDataset(entry.email!!, "email", "${entry.id}:email"))
                            }
                        } else if (hasUser) {
                            fillResponseBuilder.addDataset(buildUnlockedDataset(entry.username, "username", entry.id))
                        } else if (hasMail) {
                            fillResponseBuilder.addDataset(buildUnlockedDataset(entry.email!!, "email", entry.id))
                        } else {
                            fillResponseBuilder.addDataset(buildUnlockedDataset("", "none", entry.id))
                        }

                        // Remember username step selection for multi-step carryover
                        if (matches.size == 1 && usernameFields.isNotEmpty()) {
                            val idToRemember = if (isExplicitEmailField && hasMail) entry.email!! else entry.username.ifBlank { entry.email ?: "" }
                            AutofillCredentialStore.rememberPendingLogin(entry.id, contextKey, idToRemember)
                        }
                    }
                }
            }

            // Append "Open KeyNest" at the bottom of all unlocked responses
            val formIds = if (targetFormIds.isNotEmpty()) {
                targetFormIds
            } else if (focusedNode?.autofillId != null) {
                listOf(focusedNode.autofillId!!)
            } else if (candidateInputIds.isNotEmpty()) {
                candidateInputIds.take(3)
            } else {
                emptyList()
            }
            val allTargetIds = formIds.distinct()
            val orderedTargetIds = if (focusedAutofillId != null && allTargetIds.contains(focusedAutofillId)) {
                listOf(focusedAutofillId) + allTargetIds.filter { it != focusedAutofillId }
            } else {
                allTargetIds
            }
            if (orderedTargetIds.isNotEmpty()) {
                try {
                    val searchPresentation = RemoteViewsHelper.viewsWithSearch(packageName, "Open KeyNest", "Search or select saved logins")
                    val searchDatasetBuilder = Dataset.Builder(searchPresentation)
                        .setAuthentication(pickerSender)

                    orderedTargetIds.forEach { targetId ->
                        searchDatasetBuilder.setValue(
                            targetId,
                            null,
                            searchPresentation
                        )
                    }
                    fillResponseBuilder.addDataset(searchDatasetBuilder.build())

                    AutofillRequestStore.saveRequest(
                        authLevel = "dataset",
                        packageName = targetPackage,
                        webDomain = targetDomain,
                        structure = context.structure,
                        parser = parser,
                        requestId = request.id,
                        originatingPackage = originatingPackage,
                        overrideUsernameIds = (parser.fieldIds[AutofillInputType.UserName]?.map { it.autofillId } ?: emptyList()).distinct(),
                        overrideEmailIds = (parser.fieldIds[AutofillInputType.Email]?.map { it.autofillId } ?: emptyList()).distinct(),
                        overridePasswordIds = passwordFields.map { it.autofillId }.distinct(),
                        overrideConfirmPwIds = confirmPwFields.map { it.autofillId }.distinct(),
                        overrideOtpIds = otpFields.map { it.autofillId }.distinct()
                    )
                } catch (e: Exception) {
                    logger.error(e) { "Could not append Open KeyNest dataset: $e" }
                }
            }
        }

        // Setup SaveInfo so Android prompts the user to save/update after form submission
        val isPasswordChange = currentPwFields.isNotEmpty() && (newPwFields.isNotEmpty() || standardPwFields.isNotEmpty())
        val isSignUp = (newPwFields.isNotEmpty() || confirmPwFields.isNotEmpty()) && !isPasswordChange

        val candidateSavePwFields = when {
            newPwFields.isNotEmpty() -> newPwFields
            standardPwFields.isNotEmpty() -> standardPwFields
            passwordFields.isNotEmpty() -> passwordFields
            else -> emptyList()
        }
        val requiredSaveIds = candidateSavePwFields.map { it.autofillId }.distinct()
        val optionalSaveIds = (usernameFields.map { it.autofillId } +
                confirmPwFields.map { it.autofillId } +
                currentPwFields.map { it.autofillId }).distinct().filter { !requiredSaveIds.contains(it) }

        if (requiredSaveIds.isNotEmpty()) {
            val saveInfoBuilder = SaveInfo.Builder(
                SaveInfo.SAVE_DATA_TYPE_PASSWORD,
                requiredSaveIds.toTypedArray()
            )
            if (optionalSaveIds.isNotEmpty()) {
                saveInfoBuilder.setOptionalIds(optionalSaveIds.toTypedArray())
            }
            if (isPasswordChange) {
                saveInfoBuilder.setDescription("Update password in KeyNest")
            } else {
                saveInfoBuilder.setDescription("Save login to KeyNest")
            }
            saveInfoBuilder.setFlags(SaveInfo.FLAG_SAVE_ON_ALL_VIEWS_INVISIBLE)
            fillResponseBuilder.setSaveInfo(saveInfoBuilder.build())
        }

        try {
            callback.onSuccess(fillResponseBuilder.build())
        } catch (e: TransactionTooLargeException) {
            logger.error(e) { "Transaction too large with ${autoFillIds.size} IDs" }
            callback.onSuccess(null)
        } catch (e: Exception) {
            logger.error(e) { "Failed building FillResponse" }
            callback.onSuccess(null)
        }
    }

    override fun onSaveRequest(request: SaveRequest, callback: SaveCallback) {
        AutofillServicePluginImpl.cleanupExpiredPendingSaveData(applicationContext)
        logger.info { "Handling onSaveRequest: contexts=${request.fillContexts.size}" }
        try {
            if (request.fillContexts.isEmpty()) {
                callback.onSuccess()
                return
            }

            var username = ""
            var primaryPassword = ""
            var confirmPassword = ""
            var currentPassword = ""
            var newPassword = ""
            var targetPackage = ""
            var targetDomain = ""

            // Iterate across ALL fillContexts (supporting multi-page auth and redirects!)
            for (context in request.fillContexts) {
                val parser = AssistStructureParser(context.structure)
                if (targetPackage.isBlank()) {
                    targetPackage = parser.packageName.firstOrNull() ?: ""
                }
                if (targetDomain.isBlank()) {
                    targetDomain = parser.getPrimaryWebDomain() ?: ""
                }

                val confirmIds = (parser.fieldIds[AutofillInputType.ConfirmPassword] ?: emptyList()).map { it.autofillId }.toSet()
                val currentIds = (parser.fieldIds[AutofillInputType.CurrentPassword] ?: emptyList()).map { it.autofillId }.toSet()
                val newPwIds = (parser.fieldIds[AutofillInputType.NewPassword] ?: emptyList())
                    .filter { !confirmIds.contains(it.autofillId) }
                    .map { it.autofillId }.toSet()
                val pwIds = (parser.fieldIds[AutofillInputType.Password] ?: emptyList())
                    .filter { !confirmIds.contains(it.autofillId) && !currentIds.contains(it.autofillId) && !newPwIds.contains(it.autofillId) }
                    .map { it.autofillId }.toSet()
                val userIds = ((parser.fieldIds[AutofillInputType.UserName] ?: emptyList()) +
                        (parser.fieldIds[AutofillInputType.Email] ?: emptyList())).map { it.autofillId }.toSet()

                for (node in parser.allNodes) {
                    val value = node.autofillValue?.textValue?.toString()
                        ?: node.text?.toString()
                        ?: continue
                    if (value.isBlank()) continue

                    val id = node.autofillId ?: continue
                    if (confirmIds.contains(id)) {
                        confirmPassword = value
                    } else if (currentIds.contains(id)) {
                        currentPassword = value
                    } else if (newPwIds.contains(id)) {
                        newPassword = value
                    } else if (pwIds.contains(id)) {
                        if (primaryPassword.isBlank()) {
                            primaryPassword = value
                        }
                    } else if (userIds.contains(id)) {
                        if (username.isBlank()) {
                            username = value
                        }
                    }
                }
            }

            // Infer domain from package if webDomain is empty
            if (targetDomain.isBlank() && targetPackage.isNotBlank()) {
                targetDomain = AutofillCredentialStore.getAssociatedWebDomain(targetPackage) ?: ""
            }

            val contextKey = if (targetDomain.isNotEmpty()) targetDomain else targetPackage

            // Fallback for multi-page authentication: if username is missing, check session auth state
            if (username.isBlank()) {
                val sessionUser = AutofillCredentialStore.getSessionUsername(contextKey)
                if (!sessionUser.isNullOrBlank()) {
                    username = sessionUser
                } else {
                    val pendingLogin = AutofillCredentialStore.getValidPendingLogin(contextKey)
                    if (pendingLogin != null && pendingLogin.username.isNotBlank()) {
                        username = pendingLogin.username
                    }
                }
            }

            val isPasswordChange = currentPassword.isNotBlank() && (newPassword.isNotBlank() || primaryPassword.isNotBlank())
            val effectivePassword = when {
                newPassword.isNotBlank() -> newPassword
                primaryPassword.isNotBlank() -> primaryPassword
                currentPassword.isNotBlank() -> currentPassword
                else -> ""
            }

            // SIGN-UP VALIDATION: Confirm password validation
            // "never treat a mismatched confirmation password as the actual password."
            if (confirmPassword.isNotBlank() && effectivePassword.isNotBlank()) {
                if (confirmPassword != effectivePassword) {
                    logger.warn { "Confirmation password mismatch ($confirmPassword vs $effectivePassword). Aborting save." }
                    callback.onSuccess()
                    return
                }
            }

            if (effectivePassword.isBlank() && username.isBlank()) {
                logger.warn { "No valid credentials found in onSaveRequest." }
                callback.onSuccess()
                return
            }

            // Determine if updating an existing entry
            val matches = AutofillCredentialStore.findMatches(targetPackage, targetDomain)
            val hasExistingMatch = matches.any {
                it.username.trim().equals(username.trim(), ignoreCase = true)
            } || (matches.size == 1 && isPasswordChange)

            val isUpdate = isPasswordChange || hasExistingMatch

            // Store in plugin cache and SharedPreferences
            val effectivePackage = if (AssistStructureParser.isBrowserPackage(targetPackage)) "" else targetPackage
            val saveData = mapOf(
                "username" to username,
                "password" to effectivePassword,
                "packageName" to effectivePackage,
                "webDomain" to targetDomain,
                "isPasswordChange" to isPasswordChange.toString(),
                "isUpdate" to isUpdate.toString(),
            )
            AutofillServicePluginImpl.savePendingSaveData(applicationContext, saveData)

            // Cleanup session auth context
            AutofillCredentialStore.clearSessionAuth(contextKey)

            // Display native unobtrusive confirmation without switching away from browser
            val targetLabel = if (targetDomain.isNotEmpty()) targetDomain else targetPackage
            val msg = if (username.isNotBlank()) {
                "KeyNest: Login ready to save for $username"
            } else {
                "KeyNest: Login ready to save for $targetLabel"
            }
            Handler(Looper.getMainLooper()).post {
                Toast.makeText(applicationContext, msg, Toast.LENGTH_SHORT).show()
            }

            callback.onSuccess()
        } catch (e: Exception) {
            logger.error(e) { "Error in onSaveRequest: $e" }
            callback.onSuccess()
        }
    }
}

data class AutofillMetadata(
    val packageNames: Set<String>,
    val webDomains: Set<WebDomain>
) {
    companion object {
        const val EXTRA_NAME = "AutofillMetadata"
        private const val PACKAGE_NAMES = "packageNames"
        private const val WEB_DOMAINS = "webDomains"

        fun fromJsonString(json: String) =
            JSONObject(json).run {
                AutofillMetadata(
                    packageNames = optJSONArray(PACKAGE_NAMES).map { array, index ->
                        array.getString(index)
                    }.toSet(),
                    webDomains = optJSONArray(WEB_DOMAINS).map { array, index ->
                        WebDomain.fromJson(array.getJSONObject(index))
                    }.toSet()
                )
            }
    }

    fun toMap(): Map<Any, Any> = mapOf(
        PACKAGE_NAMES to packageNames.toList(),
        WEB_DOMAINS to webDomains.map { it.toMap() },
    )

    fun toJsonString(): String = JSONObject(toMap()).toString()
}

fun <T> JSONArray.map(f: (array: JSONArray, index: Int) -> T): List<T> {
    return (0 until length()).map { index ->
        f(this, index)
    }
}

object RemoteViewsHelper {

    fun viewsWithCredential(
        packageName: String,
        title: String,
        subtitle: String? = null,
        iconBytes: ByteArray? = null,
        isLocked: Boolean = false
    ): RemoteViews {
        val presentation = RemoteViews(packageName, R.layout.multidataset_service_list_item)
        presentation.setTextViewText(R.id.text, title)

        if (!subtitle.isNullOrBlank()) {
            presentation.setTextViewText(R.id.subtitle, subtitle)
            presentation.setViewVisibility(R.id.subtitle, View.VISIBLE)
        } else {
            presentation.setViewVisibility(R.id.subtitle, View.GONE)
        }

        presentation.setViewVisibility(R.id.badge, View.GONE)

        val rounded = if (iconBytes != null && iconBytes.isNotEmpty()) {
            getRoundedBitmap(iconBytes)
        } else null

        if (rounded != null) {
            presentation.setImageViewBitmap(R.id.icon, rounded)
        } else {
            if (isLocked) {
                presentation.setImageViewUri(R.id.icon, AutofillLockStateProvider.getFallbackIconUri(packageName))
            } else {
                presentation.setImageViewResource(R.id.icon, R.drawable.ic_person_black_24dp)
            }
        }

        if (isLocked) {
            presentation.setImageViewUri(R.id.action_icon, AutofillLockStateProvider.getLockUri(packageName))
            presentation.setViewVisibility(R.id.action_icon, View.VISIBLE)
        } else {
            presentation.setViewVisibility(R.id.action_icon, View.GONE)
        }

        return presentation
    }

    fun viewsWithTotp(
        packageName: String,
        title: String,
        subtitle: String,
        iconBytes: ByteArray? = null,
        isLocked: Boolean = false
    ): RemoteViews {
        val presentation = RemoteViews(packageName, R.layout.multidataset_service_list_item)
        presentation.setTextViewText(R.id.text, title)
        presentation.setTextViewText(R.id.subtitle, subtitle)
        presentation.setViewVisibility(R.id.subtitle, View.VISIBLE)

        presentation.setTextViewText(R.id.badge, "2FA")
        presentation.setViewVisibility(R.id.badge, View.VISIBLE)

        val rounded = if (iconBytes != null && iconBytes.isNotEmpty()) {
            getRoundedBitmap(iconBytes)
        } else null

        if (rounded != null) {
            presentation.setImageViewBitmap(R.id.icon, rounded)
        } else {
            if (isLocked) {
                presentation.setImageViewUri(R.id.icon, AutofillLockStateProvider.getFallbackTotpUri(packageName))
            } else {
                presentation.setImageViewResource(R.id.icon, R.drawable.ic_totp_24dp)
            }
        }

        if (isLocked) {
            presentation.setImageViewUri(R.id.action_icon, AutofillLockStateProvider.getLockUri(packageName))
            presentation.setViewVisibility(R.id.action_icon, View.VISIBLE)
        } else {
            presentation.setViewVisibility(R.id.action_icon, View.GONE)
        }

        return presentation
    }

    fun viewsWithSearch(
        packageName: String,
        text: String = "Open KeyNest",
        subtitle: String = "Search or select saved logins"
    ): RemoteViews {
        val presentation = RemoteViews(packageName, R.layout.multidataset_service_list_item)
        presentation.setTextViewText(R.id.text, text)
        presentation.setTextViewText(R.id.subtitle, subtitle)
        presentation.setViewVisibility(R.id.subtitle, View.VISIBLE)
        presentation.setImageViewResource(R.id.icon, R.drawable.ic_search_black_24dp)
        presentation.setViewVisibility(R.id.badge, View.GONE)
        presentation.setViewVisibility(R.id.action_icon, View.GONE)
        return presentation
    }

    fun viewsWithAuth(packageName: String, text: String): RemoteViews {
        val (title, subtitle) = parseTitleAndSubtitle(text)
        return viewsWithCredential(packageName, title, subtitle, isLocked = true)
    }

    fun viewsWithNoAuth(packageName: String, text: String): RemoteViews {
        val (title, subtitle) = parseTitleAndSubtitle(text)
        return viewsWithCredential(packageName, title, subtitle, isLocked = false)
    }

    private fun parseTitleAndSubtitle(raw: String): Pair<String, String?> {
        val openParen = raw.indexOf('(')
        val closeParen = raw.lastIndexOf(')')
        return if (openParen > 0 && closeParen > openParen) {
            val title = raw.substring(0, openParen).trim()
            val subtitle = raw.substring(openParen + 1, closeParen).trim()
            title to subtitle
        } else {
            raw to null
        }
    }

    private fun getRoundedBitmap(bytes: ByteArray, sizePx: Int = 96, cornerRadiusPx: Float = 16f): Bitmap? {
        return try {
            val original = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return null
            val scaled = Bitmap.createScaledBitmap(original, sizePx, sizePx, true)
            val output = Bitmap.createBitmap(sizePx, sizePx, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(output)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG)
            val shader = BitmapShader(scaled, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP)
            paint.shader = shader
            val rect = RectF(0f, 0f, sizePx.toFloat(), sizePx.toFloat())
            canvas.drawRoundRect(rect, cornerRadiusPx, cornerRadiusPx, paint)
            output
        } catch (e: Exception) {
            null
        }
    }
}

data class AutofillHeuristic(
    val weight: Int,
    val message: String?,
    val predicate: AssistStructure.ViewNode.(node: AssistStructure.ViewNode) -> Boolean
)

private fun MutableList<AutofillHeuristic>.heuristic(
    weight: Int,
    message: String? = null,
    predicate: AssistStructure.ViewNode.(node: AssistStructure.ViewNode) -> Boolean
) =
    add(AutofillHeuristic(weight, message, predicate))

@TargetApi(Build.VERSION_CODES.O)
private fun MutableList<AutofillHeuristic>.autofillHint(weight: Int, vararg hints: String) =
    heuristic(weight, "hint=${hints.joinToString("|")}") {
        autofillHints?.any { actual -> hints.any { it.equals(actual, ignoreCase = true) } } == true
    }

@TargetApi(Build.VERSION_CODES.O)
private fun MutableList<AutofillHeuristic>.idEntry(weight: Int, match: String) =
    heuristic(weight) { idEntry?.equals(match, ignoreCase = true) == true }

@TargetApi(Build.VERSION_CODES.O)
private fun AssistStructure.ViewNode.htmlAttribute(attr: String): String? =
    htmlInfo?.attributes?.firstOrNull { it.first.equals(attr, ignoreCase = true) }?.second

@TargetApi(Build.VERSION_CODES.O)
private fun MutableList<AutofillHeuristic>.htmlAttribute(weight: Int, attr: String, value: String) =
    heuristic(weight, "html[$attr=$value]") {
        htmlAttribute(attr).equals(value, ignoreCase = true)
    }

@TargetApi(Build.VERSION_CODES.O)
private fun MutableList<AutofillHeuristic>.htmlAttributeContains(
    weight: Int,
    attr: String,
    value: String
) =
    heuristic(weight, "html[$attr*=$value]") {
        htmlAttribute(attr)?.lowercase()?.contains(value.lowercase()) == true
    }

@TargetApi(Build.VERSION_CODES.O)
private fun MutableList<AutofillHeuristic>.browserPrediction(weight: Int, types: Set<String>) =
    BROWSER_PREDICTION_ATTRIBUTES.forEachIndexed { index, attr ->
        heuristic(weight - index, "html[$attr in $types]") {
            val prediction = htmlAttribute(attr)?.uppercase()
            prediction != null && types.contains(prediction)
        }
    }

private val BROWSER_PREDICTION_ATTRIBUTES = listOf(
    "computed-autofill-hints",
    "ua-autofill-hints",
    "crowd-sourcing-autofill-hints",
    "crowdsourcing-autofill-hints",
)

@TargetApi(Build.VERSION_CODES.O)
private fun MutableList<AutofillHeuristic>.defaults(hint: String, match: String) {
    autofillHint(900, hint)
    idEntry(800, match)
    heuristic(700) { idEntry?.lowercase()?.contains(match.lowercase()) == true }
}

@TargetApi(Build.VERSION_CODES.O)
enum class AutofillInputType(val heuristics: List<AutofillHeuristic>) {
    Password(mutableListOf<AutofillHeuristic>().apply {
        defaults(View.AUTOFILL_HINT_PASSWORD, "password")
        autofillHint(890, "current-password", "passcode", "pwd", "pass", "পাসওয়ার্ড", "গোপন কোড", "passwort", "mot de passe", "contraseña", "senha")
        htmlAttribute(880, "type", "password")
        browserPrediction(
            870, setOf(
                "PASSWORD",
                "ACCOUNT_CREATION_PASSWORD",
                "NEW_PASSWORD",
                "PROBABLY_NEW_PASSWORD",
            )
        )
        // Check standard text and numeric password input types
        heuristic(245, "password input type") {
            val classType = inputType and android.text.InputType.TYPE_MASK_CLASS
            val variation = inputType and android.text.InputType.TYPE_MASK_VARIATION
            val isTextPw = classType == android.text.InputType.TYPE_CLASS_TEXT && (
                variation == android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD ||
                variation == android.text.InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD ||
                variation == android.text.InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD
            )
            val isNumberPw = classType == android.text.InputType.TYPE_CLASS_NUMBER &&
                variation == android.text.InputType.TYPE_NUMBER_VARIATION_PASSWORD
            isTextPw || isNumberPw ||
                inputType.hasFlag(android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD) ||
                inputType.hasFlag(android.text.InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD) ||
                inputType.hasFlag(android.text.InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD)
        }
        heuristic(230, "password id pattern") { parent ->
            val id = idEntry?.lowercase() ?: ""
            val pid = parent.idEntry?.lowercase() ?: ""
            val combined = "$id $pid"
            combined.contains("password") || combined.contains("passwd") || combined.contains("pwd") ||
                combined.contains("passcode") || combined.contains("pass_word") || combined.contains("login_pass") ||
                combined.contains("user_pass")
        }
        heuristic(210, "multilingual password hint") { parent ->
            val h = hint?.lowercase() ?: ""
            val desc = contentDescription?.toString()?.lowercase() ?: ""
            val ph = parent.hint?.lowercase() ?: ""
            val pdesc = parent.contentDescription?.toString()?.lowercase() ?: ""
            val combined = "$h $desc $ph $pdesc"
            combined.contains("password") || combined.contains("passcode") || combined.contains("pwd") ||
                combined.contains("পাসওয়ার্ড") || combined.contains("গোপন কোড") ||
                combined.contains("passwort") || combined.contains("contraseña") ||
                combined.contains("mot de passe") || combined.contains("senha")
        }
    }),

    NewPassword(mutableListOf<AutofillHeuristic>().apply {
        autofillHint(920, "newPassword", "new-password", "new_password")
        htmlAttribute(910, "autocomplete", "new-password")
        idEntry(850, "newpassword")
        idEntry(845, "new_password")
        browserPrediction(
            890, setOf(
                "NEW_PASSWORD",
                "ACCOUNT_CREATION_PASSWORD",
            )
        )
        heuristic(250) {
            val id = idEntry?.lowercase() ?: ""
            val h = hint?.lowercase() ?: ""
            id.contains("new_password") || id.contains("newpassword") || h.contains("new password") || h.contains("create password") || h.contains("নতুন পাসওয়ার্ড") || h.contains("nouveau") || h.contains("nuevo")
        }
    }),

    ConfirmPassword(mutableListOf<AutofillHeuristic>().apply {
        autofillHint(940, "confirmPassword", "confirm-password", "confirm_password", "repeat-password", "repeat_password", "password_confirmation")
        htmlAttribute(930, "autocomplete", "confirm-password")
        browserPrediction(920, setOf("CONFIRMATION_PASSWORD"))
        idEntry(860, "confirm_password")
        idEntry(855, "confirmpassword")
        idEntry(850, "password_confirmation")
        idEntry(845, "password_confirm")
        idEntry(840, "repeat_password")
        idEntry(835, "repeatpassword")
        idEntry(830, "pass2")
        idEntry(825, "password2")
        heuristic(400) {
            val id = idEntry?.lowercase() ?: ""
            val h = hint?.lowercase() ?: ""
            val desc = contentDescription?.toString()?.lowercase() ?: ""
            val name = htmlAttribute("name")?.lowercase() ?: ""
            val aria = htmlAttribute("aria-label")?.lowercase() ?: ""
            val combined = "$id $h $desc $name $aria"
            combined.contains("confirm password") || combined.contains("repeat password") ||
                    combined.contains("re-enter password") || combined.contains("retype password") ||
                    combined.contains("পাসওয়ার্ড নিশ্চিত") || combined.contains("confirmer") ||
                    combined.contains("bestätigen") || combined.contains("confirmar") ||
                    id.contains("confirm") || id.contains("repeat") || id.contains("retype") ||
                    name.contains("confirm") || name.contains("repeat")
        }
    }),

    CurrentPassword(mutableListOf<AutofillHeuristic>().apply {
        autofillHint(940, "current-password", "current_password", "old-password", "old_password")
        htmlAttribute(930, "autocomplete", "current-password")
        idEntry(860, "current_password")
        idEntry(855, "currentpassword")
        idEntry(850, "old_password")
        idEntry(845, "oldpassword")
        heuristic(400) {
            val id = idEntry?.lowercase() ?: ""
            val h = hint?.lowercase() ?: ""
            val desc = contentDescription?.toString()?.lowercase() ?: ""
            val name = htmlAttribute("name")?.lowercase() ?: ""
            val aria = htmlAttribute("aria-label")?.lowercase() ?: ""
            val combined = "$id $h $desc $name $aria"
            combined.contains("current password") || combined.contains("old password") ||
                    combined.contains("existing password") || combined.contains("বর্তমান পাসওয়ার্ড") ||
                    combined.contains("mot de passe actuel") || combined.contains("contraseña actual") ||
                    id.contains("current_password") || id.contains("old_password") ||
                    name.contains("current_password") || name.contains("old_password")
        }
    }),

    Email(mutableListOf<AutofillHeuristic>().apply {
        defaults(View.AUTOFILL_HINT_EMAIL_ADDRESS, "mail")
        autofillHint(600, "email", "e-mail", "emailaddress", "email_address", "email-address", "mail address", "ইমেইল", "ই-মেইল", "correo", "courriel")
        htmlAttribute(500, "type", "email")
        browserPrediction(450, setOf("EMAIL_ADDRESS", "USERNAME_AND_EMAIL_ADDRESS"))
        heuristic(420, "email input type") {
            val variation = inputType and android.text.InputType.TYPE_MASK_VARIATION
            variation == android.text.InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS ||
                variation == android.text.InputType.TYPE_TEXT_VARIATION_WEB_EMAIL_ADDRESS ||
                inputType.hasFlag(android.text.InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS) ||
                inputType.hasFlag(android.text.InputType.TYPE_TEXT_VARIATION_WEB_EMAIL_ADDRESS)
        }
        htmlAttributeContains(400, "name", "mail")
        htmlAttributeContains(390, "id", "mail")
        heuristic(380, "email id pattern") { parent ->
            val id = idEntry?.lowercase() ?: ""
            val pid = parent.idEntry?.lowercase() ?: ""
            val combined = "$id $pid"
            combined.contains("email") || combined.contains("e_mail") || combined.contains("user_mail") ||
                combined.contains("login_mail") || combined.contains("account_mail")
        }
        heuristic(250, "hint=mail") { parent ->
            val h = hint?.lowercase() ?: ""
            val desc = contentDescription?.toString()?.lowercase() ?: ""
            val ph = parent.hint?.lowercase() ?: ""
            val pdesc = parent.contentDescription?.toString()?.lowercase() ?: ""
            val combined = "$h $desc $ph $pdesc"
            combined.contains("mail") || combined.contains("email") || combined.contains("ইমেইল") ||
                combined.contains("ই-মেইল") || combined.contains("correo") || combined.contains("courriel")
        }
        htmlAttributeContains(240, "label", "mail")
    }),

    UserName(mutableListOf<AutofillHeuristic>().apply {
        defaults(View.AUTOFILL_HINT_USERNAME, "user")
        autofillHint(
            480,
            "username", "user_name", "user id", "userid", "user_id", "login", "account",
            "member id", "identifier", "emailaddress", "phone", "phonenumber", "phone_number",
            "ইউজারনেম", "ব্যবহারকারী", "লগইন", "অ্যাকাউন্ট", "benutzername", "utilisateur", "usuario"
        )
        browserPrediction(
            450, setOf(
                "USERNAME",
                "USERNAME_AND_EMAIL_ADDRESS",
                "SINGLE_USERNAME",
                "SINGLE_USERNAME_FORGOT_PASSWORD",
                "SINGLE_USERNAME_WITH_INTERMEDIATE_VALUES",
            )
        )
        heuristic(420, "username id pattern") { parent ->
            val id = idEntry?.lowercase() ?: ""
            val pid = parent.idEntry?.lowercase() ?: ""
            val combined = "$id $pid"
            combined.contains("username") || combined.contains("user_name") || combined.contains("user_id") ||
                combined.contains("userid") || combined.contains("login_id") || combined.contains("account_name") ||
                combined.contains("member_id") || combined.contains("identifier")
        }
        htmlAttributeContains(400, "name", "user")
        htmlAttributeContains(390, "id", "user")
        htmlAttributeContains(380, "name", "login")
        htmlAttributeContains(370, "id", "login")
        heuristic(300) { parent ->
            val h = hint?.lowercase() ?: ""
            val desc = contentDescription?.toString()?.lowercase() ?: ""
            val ph = parent.hint?.lowercase() ?: ""
            val pdesc = parent.contentDescription?.toString()?.lowercase() ?: ""
            val combined = "$h $desc $ph $pdesc"
            combined.contains("login") || combined.contains("user") || combined.contains("username") ||
                combined.contains("account") || combined.contains("member") || combined.contains("identifier") ||
                combined.contains("ইউজারনেম") || combined.contains("লগইন") || combined.contains("ব্যবহারকারী") ||
                combined.contains("অ্যাকাউন্ট") || combined.contains("benutzername") ||
                combined.contains("utilisateur") || combined.contains("usuario")
        }
        htmlAttributeContains(230, "label", "user")
        htmlAttributeContains(220, "label", "login")
    }),

    Otp(mutableListOf<AutofillHeuristic>().apply {
        autofillHint(
            980,
            "sms-otp", "one-time-code", "totp", "otp", "2fa", "security code", "security-code",
            "verification-code", "verification code", "two-factor", "authenticator", "authenticator-code",
            "auth-code", "mfa", "login-code", "ওটিপি", "ভেরিফিকেশন কোড", "código",
            "code de vérification", "bestätigungscode"
        )
        htmlAttribute(960, "autocomplete", "one-time-code")
        browserPrediction(920, setOf("ONE_TIME_CODE", "OTP", "TWO_FACTOR", "VERIFICATION_CODE"))
        idEntry(880, "otp")
        idEntry(875, "totp")
        idEntry(870, "2fa")
        idEntry(865, "mfa")
        idEntry(860, "token")
        idEntry(855, "auth_code")
        idEntry(850, "verification_code")

        // Comprehensive keyword, attribute, and multi-field pattern evaluation
        heuristic(450) {
            val lowerId = idEntry?.lowercase() ?: ""
            val lowerHint = hint?.lowercase() ?: ""
            val lowerDesc = contentDescription?.toString()?.lowercase() ?: ""
            val lowerName = htmlAttribute("name")?.lowercase() ?: ""
            val lowerAria = htmlAttribute("aria-label")?.lowercase() ?: ""
            val combined = "$lowerId $lowerHint $lowerDesc $lowerName $lowerAria"

            // Strictly reject passwords, usernames, and search/coupon fields
            val isPasswordForm = combined.contains("password") || combined.contains("passphrase") || combined.contains("current-password") || combined.contains("new-password")
            val isExplicitOtp = combined.contains("one-time") || combined.contains("otp") || combined.contains("totp") || combined.contains("2fa") || combined.contains("verification") || combined.contains("authenticator") || combined.contains("security code") || combined.contains("security-code")

            if (isPasswordForm && !isExplicitOtp) {
                return@heuristic false
            }

            val isUserOrEmail = (combined.contains("username") || combined.contains("email") || combined.contains("user_id")) && !isExplicitOtp
            if (isUserOrEmail) {
                return@heuristic false
            }

            // Positive detection signals
            isExplicitOtp ||
                    lowerId.contains("totp") || lowerId.contains("otp") || lowerId.contains("2fa") ||
                    lowerId.contains("mfa") || lowerId.contains("verification") || lowerId.contains("passcode") ||
                    lowerId.contains("authcode") || lowerId.contains("auth_code") || lowerId.contains("auth-code") ||
                    lowerName.contains("totp") || lowerName.contains("otp") || lowerName.contains("2fa") ||
                    lowerName.contains("verification") || lowerName.contains("security_code") ||
                    lowerHint.contains("totp") || lowerHint.contains("otp") || lowerHint.contains("2fa") ||
                    lowerHint.contains("verification") || lowerHint.contains("authenticator") ||
                    lowerHint.contains("security code") || lowerHint.contains("6-digit") ||
                    lowerDesc.contains("verification") || lowerDesc.contains("authenticator") ||
                    combined.contains("ওটিপি") || combined.contains("ভেরিফিকেশন") || combined.contains("código de verificación") ||
                    // Multi-field verification box patterns (e.g. otp-0, otp_1, digit1, code-1)
                    lowerId.matches(Regex(".*(otp|digit|code|char)[-_]?[0-9].*")) ||
                    lowerName.matches(Regex(".*(otp|digit|code|char)[-_]?[0-9].*"))
        }
    }),
}

fun Int?.hasFlag(flag: Int) = this != null && flag and this == flag
@Suppress("unused")
fun Int.withFlag(flag: Int) = this or flag
@Suppress("unused")
fun Int.minusFlag(flag: Int) = this and flag.inv()

data class MatchedField(val heuristic: AutofillHeuristic, val autofillId: AutofillId)

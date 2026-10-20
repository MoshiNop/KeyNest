package com.moshinop.autofill_service

import android.annotation.SuppressLint
import android.app.Activity
import android.app.Activity.RESULT_OK
import android.app.Activity.RESULT_CANCELED
import android.app.Application
import android.app.PendingIntent
import android.app.assist.AssistStructure
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.service.autofill.Dataset
import android.service.autofill.FillResponse
import android.view.View
import android.view.autofill.AutofillId
import android.view.autofill.AutofillManager
import android.view.autofill.AutofillManager.EXTRA_AUTHENTICATION_RESULT
import android.view.autofill.AutofillValue
import android.widget.RemoteViews
import androidx.annotation.RequiresApi
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry
import mu.KotlinLogging
import org.json.JSONObject

private val logger = KotlinLogging.logger {}

data class PwDataset(
    val label: String,
    val username: String,
    val email: String? = null,
    val password: String,
    val otp: String? = null,
    val id: String? = null
)

@RequiresApi(Build.VERSION_CODES.O)
class AutofillServicePluginImpl(val context: Context) : MethodCallHandler,
        PluginRegistry.ActivityResultListener, PluginRegistry.NewIntentListener, ActivityAware {

    companion object {
        val REQUEST_CODE_SET_AUTOFILL_SERVICE =
            AutofillServicePlugin::class.java.hashCode() and 0xffff

        private const val PREFS_PENDING_SAVE = "keynest_pending_save"
        private const val KEY_ENCRYPTED_PENDING_DATA = "encrypted_pending_data"
        private const val KEY_LEGACY_PENDING_DATA = "pending_data"
        private const val KEY_TIMESTAMP = "timestamp"
        const val PENDING_SAVE_TTL_MS = 300_000L // Strict 5 min TTL

        private var _cleanupHandler: android.os.Handler? = null
        private fun getCleanupHandler(): android.os.Handler? {
            if (_cleanupHandler != null) return _cleanupHandler
            return try {
                val looper = android.os.Looper.getMainLooper()
                if (looper != null) {
                    val handler = android.os.Handler(looper)
                    _cleanupHandler = handler
                    handler
                } else null
            } catch (_: Throwable) {
                null
            }
        }
        private var pendingCleanupRunnable: Runnable? = null

        // In-memory cache for pending save requests captured by FlutterMyAutofillService
        var pendingSaveData: Map<String, String>? = null
        var pendingSaveTimestamp: Long = 0L

        fun schedulePendingSaveCleanup(ctx: Context?) {
            if (ctx == null) return
            val appCtx = ctx.applicationContext
            try {
                val prefs = appCtx.getSharedPreferences(PREFS_PENDING_SAVE, Context.MODE_PRIVATE)
                val ts = prefs.getLong(KEY_TIMESTAMP, 0L)
                if (ts <= 0L) return
                val elapsed = System.currentTimeMillis() - ts
                if (elapsed >= PENDING_SAVE_TTL_MS) {
                    clearPendingSaveData(appCtx)
                    return
                }
                val remaining = PENDING_SAVE_TTL_MS - elapsed
                synchronized(this) {
                    pendingCleanupRunnable?.let { getCleanupHandler()?.removeCallbacks(it) }
                    val runnable = Runnable {
                        cleanupExpiredPendingSaveData(appCtx)
                    }
                    pendingCleanupRunnable = runnable
                    getCleanupHandler()?.postDelayed(runnable, remaining)
                }
            } catch (_: Exception) {}
        }

        fun cleanupExpiredPendingSaveData(ctx: Context?): Boolean {
            if (ctx == null) return false
            try {
                val prefs = ctx.getSharedPreferences(PREFS_PENDING_SAVE, Context.MODE_PRIVATE)
                val ts = prefs.getLong(KEY_TIMESTAMP, 0L)
                if (ts <= 0L || System.currentTimeMillis() - ts >= PENDING_SAVE_TTL_MS) {
                    clearPendingSaveData(ctx)
                    return true
                }
            } catch (e: Exception) {
                try {
                    clearPendingSaveData(ctx)
                } catch (_: Exception) {}
                return true
            }
            return false
        }

        fun savePendingSaveData(ctx: Context?, data: Map<String, String>) {
            pendingSaveData = data
            pendingSaveTimestamp = System.currentTimeMillis()
            if (ctx != null) {
                try {
                    val prefs = ctx.getSharedPreferences(PREFS_PENDING_SAVE, Context.MODE_PRIVATE)
                    val json = org.json.JSONObject(data).toString()
                    val encrypted = AutofillSecurityHelper.encrypt(
                        AutofillSecurityHelper.ALIAS_PENDING_SAVE,
                        json
                    )
                    if (encrypted != null) {
                        prefs.edit()
                            .putString(KEY_ENCRYPTED_PENDING_DATA, encrypted)
                            .putLong(KEY_TIMESTAMP, System.currentTimeMillis())
                            .remove(KEY_LEGACY_PENDING_DATA) // Ensure no plaintext remains
                            .apply()
                        schedulePendingSaveCleanup(ctx)
                    } else {
                        logger.warn { "Encryption of pending save failed; refusing to write plaintext" }
                        prefs.edit().clear().apply()
                    }
                } catch (e: Exception) {
                    logger.warn { "Error saving pending-save data: ${e.message}" }
                }
            }
        }

        fun loadPendingSaveData(ctx: Context?): Map<String, String>? {
            val now = System.currentTimeMillis()
            if (pendingSaveTimestamp > 0L && (now - pendingSaveTimestamp) >= PENDING_SAVE_TTL_MS) {
                clearPendingSaveData(ctx)
                return null
            }
            if (ctx != null && cleanupExpiredPendingSaveData(ctx)) {
                clearPendingSaveData(ctx)
                return null
            }
            val memory = pendingSaveData
            if (memory != null) {
                return memory
            }
            if (ctx == null) return null
            try {
                val prefs = ctx.getSharedPreferences(PREFS_PENDING_SAVE, Context.MODE_PRIVATE)
                val ts = prefs.getLong(KEY_TIMESTAMP, 0L)
                if (ts <= 0L || System.currentTimeMillis() - ts >= PENDING_SAVE_TTL_MS) {
                    clearPendingSaveData(ctx)
                    return null
                }

                // 1. Try to read encrypted data first
                val encrypted = prefs.getString(KEY_ENCRYPTED_PENDING_DATA, null)
                if (encrypted != null) {
                    val decryptedJson = AutofillSecurityHelper.decrypt(
                        AutofillSecurityHelper.ALIAS_PENDING_SAVE,
                        encrypted
                    )
                    if (decryptedJson == null) {
                        logger.warn { "Failed to decrypt pending-save data; clearing corrupt data" }
                        clearPendingSaveData(ctx)
                        return null
                    }
                    val obj = org.json.JSONObject(decryptedJson)
                    val map = mutableMapOf<String, String>()
                    obj.keys().forEach { k -> map[k] = obj.optString(k) }
                    pendingSaveData = map
                    if (prefs.contains(KEY_LEGACY_PENDING_DATA)) {
                        prefs.edit().remove(KEY_LEGACY_PENDING_DATA).apply()
                    }
                    return map
                }

                // 2. Check for legacy plaintext pending-save data to migrate
                val legacyJson = prefs.getString(KEY_LEGACY_PENDING_DATA, null)
                if (legacyJson != null) {
                    val obj = org.json.JSONObject(legacyJson)
                    val map = mutableMapOf<String, String>()
                    obj.keys().forEach { k -> map[k] = obj.optString(k) }
                    pendingSaveData = map

                    // Migrate safely: encrypt and persist before removing legacy plaintext
                    val newEncrypted = AutofillSecurityHelper.encrypt(
                        AutofillSecurityHelper.ALIAS_PENDING_SAVE,
                        legacyJson
                    )
                    if (newEncrypted != null) {
                        prefs.edit()
                            .putString(KEY_ENCRYPTED_PENDING_DATA, newEncrypted)
                            .remove(KEY_LEGACY_PENDING_DATA)
                            .apply()
                    } else {
                        prefs.edit().remove(KEY_LEGACY_PENDING_DATA).apply()
                    }
                    return map
                }

                return null
            } catch (e: Exception) {
                logger.warn { "Error loading pending-save data: ${e.message}" }
                try {
                    clearPendingSaveData(ctx)
                } catch (_: Exception) {}
                return null
            }
        }

        fun clearPendingSaveData(ctx: Context?) {
            pendingSaveData = null
            pendingSaveTimestamp = 0L
            synchronized(this) {
                pendingCleanupRunnable?.let { getCleanupHandler()?.removeCallbacks(it) }
                pendingCleanupRunnable = null
            }
            if (ctx != null) {
                try {
                    ctx.getSharedPreferences(PREFS_PENDING_SAVE, Context.MODE_PRIVATE)
                        .edit().clear().apply()
                    AutofillSecurityHelper.deleteKey(AutofillSecurityHelper.ALIAS_PENDING_SAVE)
                } catch (e: Exception) {}
            }
        }

        var hasCompletedAutofill = false
    }

    private val autofillManager by lazy {
        requireNotNull(context.getSystemService(AutofillManager::class.java))
    }
    private val autofillPreferenceStore by lazy { AutofillPreferenceStore.getInstance(context) }
    private var requestSetAutofillServiceResult: Result? = null
    private var lastIntent: Intent? = null

    private var activityBinding: ActivityPluginBinding? = null
    private val activity get() = activityBinding?.activity
    var channel: MethodChannel? = null

    override fun onMethodCall(call: MethodCall, result: Result) {
        logger.debug { "onMethodCall ${call.method}" }
        when (call.method) {
            "hasAutofillServicesSupport" ->
                result.success(true)
            "hasEnabledAutofillServices" ->
                result.success(autofillManager.hasEnabledAutofillServices())
            "disableAutofillServices" -> {
                autofillManager.disableAutofillServices()
                AutofillCredentialStore.clearAll(context)
                logger.info { "Disabled autofill services and purged AutofillCredentialStore" }
                result.success(null)
            }
            "requestSetAutofillService" -> {
                val intent = Intent(Settings.ACTION_REQUEST_SET_AUTOFILL_SERVICE).apply {
                    data = Uri.parse("package:${context.packageName}")
                }
                logger.debug { "enableService(): intent=$intent for package=${context.packageName}" }
                requestSetAutofillServiceResult = result
                val act = activity
                if (act != null) {
                    act.startActivityForResult(intent, REQUEST_CODE_SET_AUTOFILL_SERVICE)
                } else {
                    intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
                    context.startActivity(intent)
                    result.success(true)
                }
            }
            "getBrowserAutofillStatus" -> {
                result.success(BrowserAutofill.queryStatus(context).map { it.toMap() })
            }
            "openBrowserAutofillSettings" -> {
                val packageName = call.argument<String>("packageName")
                    ?: throw IllegalArgumentException("Missing `packageName` argument.")
                val intent = BrowserAutofill.settingsIntent(packageName)
                val act = this.activity
                if (act == null) {
                    logger.warn { "No activity available to open $intent" }
                    result.success(false)
                    return
                }
                try {
                    act.startActivity(intent)
                    result.success(true)
                } catch (e: Exception) {
                    logger.warn(e) { "Unable to open browser settings $intent" }
                    result.success(false)
                }
            }
            "getAutofillMetadata" -> {
                val intent = lastIntent ?: activity?.intent
                var metadata = intent?.getStringExtra(
                    AutofillMetadata.EXTRA_NAME
                )?.let(AutofillMetadata.Companion::fromJsonString)
                if (metadata == null && (AutofillRequestStore.targetPackageName != null || AutofillRequestStore.targetWebDomain != null)) {
                    val pkgs = listOfNotNull(AutofillRequestStore.targetPackageName).filter { it.isNotBlank() }.toSet()
                    val domains = listOfNotNull(AutofillRequestStore.targetWebDomain).filter { it.isNotBlank() }.map { WebDomain(null, it) }.toSet()
                    metadata = AutofillMetadata(pkgs, domains)
                }
                logger.debug { "Got metadata: $metadata" }
                result.success(metadata?.toMap())
            }
            "resultWithDataset" -> {
                val label = call.argument<String>("label") ?: "KeyNest"
                val username = call.argument<String>("username") ?: ""
                val email = call.argument<String>("email")?.takeIf { it.isNotBlank() }
                val password = call.argument<String>("password") ?: ""
                val otp = call.argument<String>("otp")
                val id = call.argument<String>("id")
                resultWithDatasets(listOf(PwDataset(label, username, email, password, otp, id)), result)
            }
            "resultWithDatasets" -> {
                val datasetsArg = call.argument<List<Map<String, Any?>>>("datasets") ?: emptyList()
                val list = datasetsArg.map { item ->
                    PwDataset(
                        label = item["label"] as? String ?: "KeyNest",
                        username = item["username"] as? String ?: "",
                        email = (item["email"] as? String)?.takeIf { it.isNotBlank() },
                        password = item["password"] as? String ?: "",
                        otp = item["otp"] as? String,
                        id = item["id"] as? String
                    )
                }
                resultWithDatasets(list, result)
            }
            "getPendingSaveRequest" -> {
                val data = loadPendingSaveData(context) ?: run {
                    val intent = lastIntent ?: activity?.intent
                    val route = intent?.getStringExtra("route")
                    if (route == "/autofill_save") {
                        mapOf(
                            "username" to (intent.getStringExtra("saveUsername") ?: ""),
                            "password" to (intent.getStringExtra("savePassword") ?: ""),
                            "packageName" to (intent.getStringExtra("savePackageName") ?: ""),
                            "webDomain" to (intent.getStringExtra("saveWebDomain") ?: ""),
                            "isPasswordChange" to (intent.getStringExtra("isPasswordChange") ?: "false"),
                            "isUpdate" to (intent.getStringExtra("isUpdate") ?: "false"),
                        )
                    } else {
                        null
                    }
                }
                result.success(data)
            }
            "clearPendingSaveRequest" -> {
                clearPendingSaveData(context)
                result.success(true)
            }
            "syncCredentials" -> {
                val listArg = call.argument<List<Map<String, Any?>>>("entries") ?: emptyList()
                val entries = listArg.map { item ->
                    val otpSecret = item["otpSecret"] as? String
                    val otpAlgorithm = item["otpAlgorithm"] as? String ?: "SHA1"
                    val otpPeriod = (item["otpPeriod"] as? Number)?.toInt() ?: 30
                    val otpDigits = (item["otpDigits"] as? Number)?.toInt() ?: 6
                    val hasTotp = (item["hasTotp"] as? Boolean) ?: (!otpSecret.isNullOrBlank() || item["otp"] != null)
                    val iconBytes = item["icon"] as? ByteArray

                    val email = (item["email"] as? String)?.takeIf { it.isNotBlank() }

                    NativeAutofillEntry(
                        id = item["id"] as? String ?: "",
                        label = item["label"] as? String ?: "KeyNest",
                        username = item["username"] as? String ?: "",
                        email = email,
                        password = item["password"] as? String ?: "",
                        urls = (item["urls"] as? List<*>)?.mapNotNull { it as? String }
                            ?.map { it.trim() }
                            ?.filter { it.isNotEmpty() && !it.startsWith("androidapp://", ignoreCase = true) } ?: emptyList(),
                        packageNames = (item["packageNames"] as? List<*>)?.mapNotNull { it as? String }
                            ?.map { it.trim().lowercase() }
                            ?.filter { it.isNotEmpty() && !AssistStructureParser.isBrowserPackage(it) } ?: emptyList(),
                        registrableDomains = (item["registrableDomains"] as? List<*>)?.mapNotNull { it as? String }
                            ?.map { it.trim().lowercase().removePrefix("www.").trim('.') }
                            ?.filter { it.isNotEmpty() && it.contains(".") } ?: emptyList(),
                        otp = item["otp"] as? String,
                        otpSecret = otpSecret,
                        otpAlgorithm = otpAlgorithm,
                        otpPeriod = otpPeriod,
                        otpDigits = otpDigits,
                        hasTotp = hasTotp,
                        iconBytes = iconBytes,
                        requireReprompt = item["requireReprompt"] as? Boolean ?: false,
                        lastUsedTimestamp = (item["lastUsed"] as? Number)?.toLong() ?: 0L
                    )
                }
                val autoLockSec = call.argument<Int>("autoLockSeconds") ?: AutofillCredentialStore.autoLockSeconds
                AutofillCredentialStore.sync(entries, autoLockSec, context)
                logger.info { "Synchronized ${entries.size} credentials to AutofillCredentialStore (autoLockSec=$autoLockSec)" }
                result.success(true)
            }
            "cacheSessionTokens" -> {
                val tokens = call.argument<Map<String, String>>("tokens") ?: emptyMap()
                AutofillCredentialStore.cacheSessionTokens(tokens)
                result.success(true)
            }
            "getSessionTokens" -> {
                val tokens = AutofillCredentialStore.getSessionTokens()
                result.success(tokens)
            }
            "clearSessionTokens" -> {
                AutofillCredentialStore.clearSessionTokens()
                result.success(true)
            }
            "isVaultUnlocked" -> {
                result.success(AutofillCredentialStore.isUnlockedAndActive())
            }
            "touchActive" -> {
                AutofillCredentialStore.touchActive()
                result.success(true)
            }
            "getLastActiveTimestamp" -> {
                result.success(AutofillCredentialStore.lastActiveTimestamp)
            }
            "setAutoLockDuration" -> {
                val sec = call.argument<Int>("seconds") ?: 300
                AutofillCredentialStore.setAutoLockSettings(sec)
                result.success(true)
            }
            "clearCredentials" -> {
                AutofillCredentialStore.clear()
                clearPendingSaveData(context)
                AutofillRequestStore.clear()
                logger.info { "Cleared AutofillCredentialStore, request store, and pending save data" }
                result.success(true)
            }
            "clearAllCredentials" -> {
                AutofillCredentialStore.clearAll(context)
                clearPendingSaveData(context)
                AutofillRequestStore.clear()
                logger.info { "Cleared all credentials, metadata, request store, and pending save data" }
                result.success(true)
            }
            "rememberPendingLogin" -> {
                val entryId = call.argument<String>("entryId") ?: ""
                val verifiedContext = call.argument<String>("verifiedContext") ?: ""
                val username = call.argument<String>("username") ?: ""
                AutofillCredentialStore.rememberPendingLogin(entryId, verifiedContext, username)
                result.success(true)
            }
            "getPendingLogin" -> {
                val contextArg = call.argument<String>("currentContext") ?: ""
                val pending = AutofillCredentialStore.getValidPendingLogin(contextArg)
                if (pending != null) {
                    result.success(
                        mapOf(
                            "entryId" to pending.entryId,
                            "verifiedContext" to pending.verifiedContext,
                            "username" to pending.username,
                            "createdAt" to pending.createdAt
                        )
                    )
                } else {
                    result.success(null)
                }
            }
            "clearPendingLogin" -> {
                AutofillCredentialStore.clearPendingLogin()
                result.success(true)
            }
            "getDiagnostics" -> {
                val currentService = try {
                    Settings.Secure.getString(context.contentResolver, "autofill_service") ?: ""
                } catch (e: Exception) {
                    ""
                }
                val isCurrent = currentService.contains(context.packageName)
                result.success(
                    mapOf(
                        "sdkInt" to Build.VERSION.SDK_INT,
                        "hasAutofillServicesSupport" to true,
                        "hasEnabledAutofillServices" to autofillManager.hasEnabledAutofillServices(),
                        "isAutofillSupported" to autofillManager.isAutofillSupported,
                        "currentAutofillService" to currentService,
                        "isKeyNestDefault" to isCurrent,
                        "servicePackage" to context.packageName,
                    )
                )
            }
            "getPreferences" -> {
                result.success(
                    autofillPreferenceStore.autofillPreferences.toMap()
                )
            }
            "hasPendingAutofillRequest" -> {
                val intent = lastIntent ?: activity?.intent
                val isLauncher = intent?.let { it.action == Intent.ACTION_MAIN && it.hasCategory(Intent.CATEGORY_LAUNCHER) } == true
                if (isLauncher) {
                    result.success(mapOf(
                        "hasRequest" to false,
                        "forcePicker" to false,
                        "selectedEntryId" to null
                    ))
                    return
                }
                val hasStructure = intent?.extras?.getParcelable<AssistStructure>(AutofillManager.EXTRA_ASSIST_STRUCTURE) != null ||
                        FlutterMyAutofillService.latestStructure != null ||
                        AutofillRequestStore.hasActiveRequest
                val route = intent?.getStringExtra("route")
                val isOpenKeyNestAction = intent?.action == "com.moshinop.autofill_service.OPEN_KEYNEST"
                val isFillEntryAction = intent?.action == "com.moshinop.autofill_service.FILL_ENTRY"
                val selectedId = intent?.getStringExtra("selectedEntryId") ?: AutofillRequestStore.selectedEntryId
                val forcePicker = intent?.getBooleanExtra("forceCredentialPicker", false) == true ||
                        isOpenKeyNestAction ||
                        (AutofillRequestStore.pendingAuthLevel == "dataset" && selectedId == null)
                val hasRequest = hasStructure || route == "/autofill" || isOpenKeyNestAction || isFillEntryAction || forcePicker || AutofillRequestStore.hasActiveRequest
                result.success(mapOf(
                    "hasRequest" to hasRequest,
                    "forcePicker" to forcePicker,
                    "selectedEntryId" to selectedId
                ))
            }
            "getSelectedEntryId" -> {
                val id = (lastIntent ?: activity?.intent)?.getStringExtra("selectedEntryId")
                    ?: AutofillRequestStore.selectedEntryId
                result.success(id)
            }
            "cancelAutofill" -> {
                if (hasCompletedAutofill) {
                    logger.debug { "Ignoring cancelAutofill because autofill was already completed successfully." }
                    result.success(true)
                    return
                }
                AutofillRequestStore.clear()
                val act = this.activity
                if (act != null && isAutofillActivity(act)) {
                    act.setResult(RESULT_CANCELED)
                    act.finish()
                }
                result.success(true)
            }
            "setPreferences" -> {
                val prefs = call.argument<Map<String, Any>>("preferences")?.let { data ->
                    AutofillPreferences.fromJsonValue(data)
                } ?: throw IllegalArgumentException("Invalid preferences object.")
                autofillPreferenceStore.autofillPreferences = prefs
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun resultWithDatasets(pwDatasets: List<PwDataset>, result: Result) {
        val act = requireNotNull(this.activity) { "No activity available to return autofill dataset" }
        val currentIntent = lastIntent ?: act.intent
        try {
            currentIntent?.setExtrasClassLoader(context.classLoader)
        } catch (e: Exception) {
            logger.warn(e) { "Could not setExtrasClassLoader" }
        }

        val structureParcel: AssistStructure? =
            (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                currentIntent?.getParcelableExtra(AutofillManager.EXTRA_ASSIST_STRUCTURE, AssistStructure::class.java)
            } else {
                @Suppress("DEPRECATION")
                currentIntent?.getParcelableExtra(AutofillManager.EXTRA_ASSIST_STRUCTURE)
            }) ?: AutofillRequestStore.latestStructure ?: FlutterMyAutofillService.latestStructure

        val structure = if (structureParcel != null) {
            AssistStructureParser(structureParcel)
        } else {
            AutofillRequestStore.latestParser ?: FlutterMyAutofillService.latestParser
        }

        if (structure == null && AutofillRequestStore.passwordFieldIds.isEmpty() && AutofillRequestStore.usernameFieldIds.isEmpty()) {
            logger.info { "No structure, parser, or cached field IDs available. (activity: $activity)" }
            result.success(false)
            return
        }

        val datasetResponseBuilder = FillResponse.Builder()

        // Pre-compute all identified form field IDs
        val parsedPwFields = structure?.let {
            ((it.fieldIds[AutofillInputType.Password] ?: emptyList()) +
                    (it.fieldIds[AutofillInputType.NewPassword] ?: emptyList()) +
                    (it.fieldIds[AutofillInputType.CurrentPassword] ?: emptyList())).map { f -> f.autofillId }
        } ?: emptyList()
        val allPwFieldIds = (parsedPwFields + AutofillRequestStore.passwordFieldIds).distinct()

        val parsedConfirmPwFields = structure?.let {
            (it.fieldIds[AutofillInputType.ConfirmPassword] ?: emptyList()).map { f -> f.autofillId }
        } ?: emptyList()
        val allConfirmPwFieldIds = (parsedConfirmPwFields + AutofillRequestStore.confirmPwFieldIds).distinct()

        val parsedUserFields = structure?.let {
            (it.fieldIds[AutofillInputType.UserName] ?: emptyList()).map { f -> f.autofillId }
        } ?: emptyList()
        val allUserFieldIds = (parsedUserFields + AutofillRequestStore.usernameFieldIds).distinct()

        val parsedEmailFields = structure?.let {
            (it.fieldIds[AutofillInputType.Email] ?: emptyList()).map { f -> f.autofillId }
        } ?: emptyList()
        val allEmailFieldIds = (parsedEmailFields + AutofillRequestStore.emailFieldIds).distinct()

        val parsedOtpFields = structure?.let {
            (it.fieldIds[AutofillInputType.Otp] ?: emptyList()).map { f -> f.autofillId }
        } ?: emptyList()
        val allOtpFieldIds = (parsedOtpFields + AutofillRequestStore.otpFieldIds).distinct()

        val targetPackage = structure?.packageName?.firstOrNull() ?: AutofillRequestStore.targetPackageName ?: ""
        val primaryDomain = structure?.getPrimaryWebDomain() ?: AutofillRequestStore.targetWebDomain ?: ""
        if (pwDatasets.isNotEmpty() && AutofillCredentialStore.isLocked) {
            AutofillCredentialStore.isLocked = false
        }
        val isStoreLocked = AutofillCredentialStore.isLocked

        val storeMatches = if (targetPackage.isNotBlank() || primaryDomain.isNotBlank()) {
            AutofillCredentialStore.findMatches(targetPackage, primaryDomain)
        } else {
            emptyList()
        }

        val pwDatasetIds = pwDatasets.mapNotNull { it.id?.substringBefore(":") }.toSet()
        val additionalDatasets = mutableListOf<PwDataset>()
        for (entry in storeMatches.filter { it.id !in pwDatasetIds }) {
            val hasUser = entry.username.isNotBlank()
            val hasMail = !entry.email.isNullOrBlank() && !entry.email.equals(entry.username, ignoreCase = true)
            if (hasUser && hasMail) {
                additionalDatasets.add(
                    PwDataset(
                        label = entry.label,
                        username = entry.username,
                        email = entry.email,
                        password = entry.password,
                        otp = entry.otp,
                        id = "${entry.id}:username"
                    )
                )
                additionalDatasets.add(
                    PwDataset(
                        label = entry.label,
                        username = entry.email!!,
                        email = entry.email,
                        password = entry.password,
                        otp = entry.otp,
                        id = "${entry.id}:email"
                    )
                )
            } else {
                additionalDatasets.add(
                    PwDataset(
                        label = entry.label,
                        username = entry.username.ifBlank { entry.email ?: "" },
                        email = entry.email,
                        password = entry.password,
                        otp = entry.otp,
                        id = entry.id
                    )
                )
            }
        }
        val allDatasets = pwDatasets + additionalDatasets

        var firstDataset: Dataset? = null
        allDatasets.forEach { pw ->
            val entryIcon = pw.id?.let { AutofillCredentialStore.getEntryById(it)?.iconBytes }
            val userPresentation = RemoteViewsHelper.viewsWithCredential(
                packageName = context.packageName,
                title = pw.label,
                subtitle = pw.username.ifBlank { null },
                iconBytes = entryIcon,
                isLocked = isStoreLocked
            )
            val pwPresentation = RemoteViewsHelper.viewsWithCredential(
                packageName = context.packageName,
                title = pw.label,
                subtitle = if (pw.username.isNotBlank()) pw.username else "Password",
                iconBytes = entryIcon,
                isLocked = isStoreLocked
            )
            val otpPresentation = RemoteViewsHelper.viewsWithTotp(
                packageName = context.packageName,
                title = pw.label,
                subtitle = "TOTP",
                iconBytes = entryIcon,
                isLocked = isStoreLocked
            )

            val datasetBuilder = Dataset.Builder(userPresentation)
            datasetBuilder.setId(pw.id ?: pw.label)

            val filledAutofillIds = mutableSetOf<AutofillId>()

            // 1. Fill password fields (from parser + preserved in AutofillRequestStore)
            allPwFieldIds.forEach { fieldId ->
                if (filledAutofillIds.add(fieldId)) {
                    datasetBuilder.setValue(
                        fieldId,
                        AutofillValue.forText(pw.password),
                        pwPresentation
                    )
                }
            }

            // 1b. Fill confirm password fields
            allConfirmPwFieldIds.forEach { fieldId ->
                if (filledAutofillIds.add(fieldId)) {
                    datasetBuilder.setValue(
                        fieldId,
                        AutofillValue.forText(pw.password),
                        pwPresentation
                    )
                }
            }

            // 2. Fill username and email fields (from parser + preserved in AutofillRequestStore)
            val emailVal = pw.email?.takeIf { it.isNotBlank() } ?: pw.username
            val userVal = pw.username.ifBlank { pw.email ?: "" }

            val dedicatedEmailIds = allEmailFieldIds.filter { it !in allUserFieldIds }
            val dedicatedUserIds = allUserFieldIds.filter { it !in allEmailFieldIds }
            val sharedUserIds = (allUserFieldIds + allEmailFieldIds).filter { it !in dedicatedEmailIds && it !in dedicatedUserIds }.distinct()

            dedicatedEmailIds.forEach { fieldId ->
                if (filledAutofillIds.add(fieldId)) {
                    datasetBuilder.setValue(
                        fieldId,
                        AutofillValue.forText(emailVal),
                        userPresentation
                    )
                }
            }

            dedicatedUserIds.forEach { fieldId ->
                if (filledAutofillIds.add(fieldId)) {
                    datasetBuilder.setValue(
                        fieldId,
                        AutofillValue.forText(userVal),
                        userPresentation
                    )
                }
            }

            sharedUserIds.forEach { fieldId ->
                if (filledAutofillIds.add(fieldId)) {
                    datasetBuilder.setValue(
                        fieldId,
                        AutofillValue.forText(userVal),
                        userPresentation
                    )
                }
            }

            // 3. Fill OTP/TOTP if field detected and code available
            val otpCode = pw.otp?.ifBlank { null } ?: pw.id?.let { entryId ->
                AutofillCredentialStore.getEntryById(entryId)?.let { entry ->
                    if (entry.hasTotp) {
                        KeyNestTotp.generateTotp(
                            secretBase32 = entry.otpSecret ?: entry.otp,
                            algorithm = entry.otpAlgorithm,
                            period = entry.otpPeriod,
                            digits = entry.otpDigits
                        )
                    } else null
                }
            }

            if (!otpCode.isNullOrBlank()) {
                if (allOtpFieldIds.size == otpCode.length) {
                    allOtpFieldIds.forEachIndexed { i, fieldId ->
                        if (filledAutofillIds.add(fieldId)) {
                            datasetBuilder.setValue(
                                fieldId,
                                AutofillValue.forText(otpCode[i].toString()),
                                otpPresentation
                            )
                        }
                    }
                } else {
                    allOtpFieldIds.forEach { fieldId ->
                        if (filledAutofillIds.add(fieldId)) {
                            datasetBuilder.setValue(
                                fieldId,
                                AutofillValue.forText(otpCode),
                                otpPresentation
                            )
                        }
                    }
                }
            }

            // 4. Fallback if no categorized field was found: fill focused or first text field
            if (filledAutofillIds.isEmpty()) {
                val targetAutofillId = AutofillRequestStore.focusedAutofillId
                    ?: structure?.allNodes?.firstOrNull { it.isFocused && it.autofillId != null }?.autofillId
                    ?: structure?.allNodes?.firstOrNull { it.autofillId != null && it.autofillType == View.AUTOFILL_TYPE_TEXT }?.autofillId

                if (targetAutofillId != null) {
                    val fallbackValue = if (!otpCode.isNullOrBlank() && allOtpFieldIds.isNotEmpty()) {
                        otpCode
                    } else if (pw.username.isNotBlank()) pw.username else pw.password
                    val fallbackPresentation = if (!otpCode.isNullOrBlank() && allOtpFieldIds.isNotEmpty()) {
                        otpPresentation
                    } else if (pw.username.isNotBlank()) userPresentation else pwPresentation
                    datasetBuilder.setValue(
                        targetAutofillId,
                        AutofillValue.forText(fallbackValue),
                        fallbackPresentation
                    )
                    filledAutofillIds.add(targetAutofillId)
                }
            }

            val builtDataset = datasetBuilder.build()
            if (firstDataset == null) {
                firstDataset = builtDataset
            }
            datasetResponseBuilder.addDataset(builtDataset)
        }

        val sourceIntent = lastIntent ?: act.intent
        val authLevel = sourceIntent?.getStringExtra("autofillAuthLevel")
            ?: AutofillRequestStore.pendingAuthLevel
            ?: "response"

        // Always append "Open KeyNest" dataset to the response so that after authentication
        // and credential return, Open KeyNest remains available in the autofill suggestions.
        try {
            val searchPresentation = RemoteViewsHelper.viewsWithSearch(context.packageName, "Open KeyNest")
            val pickerIntent = Intent(sourceIntent).apply {
                action = "com.moshinop.autofill_service.OPEN_KEYNEST"
                putExtra("forceCredentialPicker", true)
                putExtra("autofillAuthLevel", "dataset")
                putExtra("route", "/autofill")
                putExtra("initial_route", "/autofill")
                AutofillRequestStore.activeRequestId?.let { putExtra("autofillRequestId", it) }
            }
            val piFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
            val pickerSender = PendingIntent.getActivity(context, 1, pickerIntent, piFlags).intentSender
            val searchDatasetBuilder = Dataset.Builder(searchPresentation).setAuthentication(pickerSender)
            val parsedAutoFillIds: List<AutofillId> = structure?.autoFillIds ?: emptyList()
            val allTargetIds: List<AutofillId> = (allPwFieldIds + allConfirmPwFieldIds + allUserFieldIds + allOtpFieldIds + 
                parsedAutoFillIds + 
                AutofillRequestStore.allFieldIds).distinct()
            allTargetIds.forEach { targetId ->
                searchDatasetBuilder.setValue(targetId, null, searchPresentation)
            }
            datasetResponseBuilder.addDataset(searchDatasetBuilder.build())
        } catch (e: Exception) {
            logger.warn(e) { "Could not append Open KeyNest to response datasets: $e" }
        }

        val isSpecificCredentialSelected = pwDatasets.isNotEmpty()
        val isOpenKeyNest = sourceIntent?.action == "com.moshinop.autofill_service.OPEN_KEYNEST" ||
            sourceIntent?.getBooleanExtra("forceCredentialPicker", false) == true ||
            (AutofillRequestStore.pendingAuthLevel == "dataset" && AutofillRequestStore.selectedEntryId.isNullOrBlank() && sourceIntent?.action != "com.moshinop.autofill_service.FILL_ENTRY")
        val isOpenKeyNestWithoutSelection = isOpenKeyNest && !isSpecificCredentialSelected

        val replyIntent = Intent()
        if (!isOpenKeyNestWithoutSelection && firstDataset != null) {
            // Android Autofill framework:
            // When a credential was selected (either via direct suggestion tap or in KeyNest autofill sheet),
            // returning the Dataset directly immediately autofills the browser/app fields
            // via Session.autoFill(...) on the first tap without requiring the user to tap a second time.
            replyIntent.putExtra(EXTRA_AUTHENTICATION_RESULT, firstDataset)
            if (isOpenKeyNest) {
                // When opened via Open KeyNest / picker, setting EXTRA_AUTHENTICATION_RESULT_EPHEMERAL_DATASET
                // tells Android (Session.java) not to overwrite the "Open KeyNest" dataset at datasetIdx.
                // This ensures "Open KeyNest" remains in the suggestion popup after autofill!
                replyIntent.putExtra("android.view.autofill.extra.AUTHENTICATION_RESULT_EPHEMERAL_DATASET", true)
            }
        } else {
            // When opened via Open KeyNest / manual picker without a specific selection,
            // return the entire FillResponse so Android presents the full suggestion list.
            replyIntent.putExtra(EXTRA_AUTHENTICATION_RESULT, datasetResponseBuilder.build())
        }

        // Remember login context for subsequent autofill requests and multi-step carryover
        val contextKey = if (!primaryDomain.isNullOrBlank()) primaryDomain else (structure?.packageName?.firstOrNull() ?: AutofillRequestStore.targetPackageName ?: "")
        if (pwDatasets.size == 1 && contextKey.isNotBlank()) {
            val pw = pwDatasets.first()
            val recordId = pw.id?.takeIf { it.isNotBlank() } ?: pw.label
            if (recordId.isNotBlank()) {
                AutofillCredentialStore.rememberPendingLogin(recordId, contextKey, pw.username)
            }
        }

        AutofillCredentialStore.touchActive()
        hasCompletedAutofill = true
        logger.info { "Returning authentication result intent: $replyIntent (authLevel=$authLevel, hasDataset=${firstDataset != null})" }

        act.setResult(RESULT_OK, replyIntent)
        act.finish()
        result.success(true)
    }

    fun isAutofillActivity(act: Activity): Boolean {
        val intent = lastIntent ?: act.intent ?: return false
        val route = intent.getStringExtra("route")
        val initialRoute = intent.getStringExtra("initial_route")
        val action = intent.action
        val forcePicker = intent.getBooleanExtra("forceCredentialPicker", false)
        val hasStructure = intent.hasExtra(AutofillManager.EXTRA_ASSIST_STRUCTURE)
        val isLauncher = action == Intent.ACTION_MAIN && intent.hasCategory(Intent.CATEGORY_LAUNCHER)
        if (isLauncher) return false
        return route == "/autofill" || initialRoute == "/autofill" || action == "com.moshinop.autofill_service.OPEN_KEYNEST" || action == "com.moshinop.autofill_service.FILL_ENTRY" || forcePicker || hasStructure
    }

    private fun tryFastFillEntry(intent: Intent?, act: Activity): Boolean {
        if (intent == null) return false
        val action = intent.action
        val entryId = intent.getStringExtra("selectedEntryId")
        if (action != "com.moshinop.autofill_service.FILL_ENTRY" || entryId.isNullOrBlank()) {
            return false
        }
        if (!AutofillCredentialStore.isUnlockedAndActive()) {
            return false
        }
        val entry = AutofillCredentialStore.getEntryById(entryId) ?: return false
        val isTotp = intent.getBooleanExtra("isTotp", false)
        if (entry.password.isEmpty() && (!entry.hasTotp || !isTotp)) {
            return false
        }
        val otpCode = if (isTotp && entry.hasTotp) {
            KeyNestTotp.generateTotp(
                secretBase32 = entry.otpSecret ?: entry.otp,
                algorithm = entry.otpAlgorithm,
                period = entry.otpPeriod,
                digits = entry.otpDigits
            )
        } else null

        val fillIdentifier = intent.getStringExtra("fillIdentifier")
        val chosenUser = when (fillIdentifier) {
            "email" -> entry.email?.takeIf { it.isNotBlank() } ?: entry.username
            "username" -> entry.username.ifBlank { entry.email ?: "" }
            else -> entry.username.ifBlank { entry.email ?: "" }
        }

        val pwDataset = PwDataset(
            id = entry.id,
            label = entry.label,
            username = chosenUser,
            email = entry.email,
            password = entry.password,
            otp = otpCode
        )
        lastIntent = intent
        var filledSuccessfully = false
        resultWithDatasets(listOf(pwDataset), object : Result {
            override fun success(result: Any?) {
                filledSuccessfully = true
                logger.info { "Fast-fill succeeded for entry $entryId without re-prompting." }
            }
            override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                filledSuccessfully = false
                logger.warn { "Fast-fill error: $errorCode - $errorMessage" }
            }
            override fun notImplemented() {
                filledSuccessfully = false
            }
        })
        return filledSuccessfully
    }

    override fun onNewIntent(intent: Intent): Boolean {
        hasCompletedAutofill = false
        lastIntent = intent
        logger.info { "Received new intent: $intent" }
        val act = activityBinding?.activity ?: this.activity
        if (act != null && tryFastFillEntry(intent, act)) {
            return true
        }
        val action = intent.action
        val isLauncher = action == Intent.ACTION_MAIN && intent.hasCategory(Intent.CATEGORY_LAUNCHER)
        if (isLauncher) {
            logger.info { "Main launcher intent received, clearing stale autofill session." }
            AutofillRequestStore.clear()
            FlutterMyAutofillService.latestStructure = null
            FlutterMyAutofillService.latestParser = null
            channel?.invokeMethod("onAutofillDismissed", null)
            return false
        }
        val entryId = intent.getStringExtra("selectedEntryId")
        if (entryId != null) {
            AutofillRequestStore.selectedEntryId = entryId
        }
        val route = intent.getStringExtra("route")
        val forcePicker = intent.getBooleanExtra("forceCredentialPicker", false)
        if (route == "/autofill" || intent.hasExtra(AutofillManager.EXTRA_ASSIST_STRUCTURE) || forcePicker || action == "com.moshinop.autofill_service.OPEN_KEYNEST" || action == "com.moshinop.autofill_service.FILL_ENTRY") {
            channel?.invokeMethod("onAutofillRequest", mapOf(
                "requestId" to intent.getIntExtra("autofillRequestId", 0),
                "forcePicker" to forcePicker,
                "selectedEntryId" to entryId
            ))
        }
        return false
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == REQUEST_CODE_SET_AUTOFILL_SERVICE) {
            requestSetAutofillServiceResult?.let { res ->
                requestSetAutofillServiceResult = null
                res.success(resultCode == RESULT_OK)
            } ?: logger.warn { "Got activity result for SET_AUTOFILL_SERVICE without active result callback." }
            return true
        }
        return false
    }

    private var lifecycleCallbacks: Application.ActivityLifecycleCallbacks? = null

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addActivityResultListener(this)
        binding.addOnNewIntentListener(this)

        val initIntent = binding.activity.intent
        lastIntent = initIntent
        val entryId = initIntent?.getStringExtra("selectedEntryId")
        if (entryId != null) {
            AutofillRequestStore.selectedEntryId = entryId
        }

        if (tryFastFillEntry(initIntent, binding.activity)) {
            return
        }

        AutofillRequestStore.onCancelledListener = { reqId ->
            activity?.runOnUiThread {
                val act = activity
                if (act != null && isAutofillActivity(act) && !hasCompletedAutofill) {
                    logger.info { "Closing autofill activity for cancelled request $reqId" }
                    act.finish()
                }
                channel?.invokeMethod("onAutofillCancelled", mapOf("requestId" to reqId))
            }
        }

        val callbacks = object : Application.ActivityLifecycleCallbacks {
            override fun onActivityCreated(act: Activity, savedInstanceState: Bundle?) {}
            override fun onActivityStarted(act: Activity) {}
            override fun onActivityResumed(act: Activity) {
                if (act == activity) {
                    AutofillCredentialStore.touchActive()
                }
            }
            override fun onActivityPaused(act: Activity) {}
            override fun onActivityStopped(act: Activity) {
                if (act == activity && isAutofillActivity(act) && !hasCompletedAutofill) {
                    if (!AutofillCredentialStore.isUnlockedAndActive()) {
                        logger.info { "Autofill activity stopped in background without completing, cleaning up." }
                        AutofillRequestStore.clear()
                        act.finish()
                    }
                }
            }
            override fun onActivitySaveInstanceState(act: Activity, outState: Bundle) {}
            override fun onActivityDestroyed(act: Activity) {}
        }
        lifecycleCallbacks = callbacks
        binding.activity.application?.registerActivityLifecycleCallbacks(callbacks)
    }

    override fun onDetachedFromActivity() {
        lifecycleCallbacks?.let {
            activityBinding?.activity?.application?.unregisterActivityLifecycleCallbacks(it)
            lifecycleCallbacks = null
        }
        AutofillRequestStore.onCancelledListener = null
        activityBinding?.removeActivityResultListener(this)
        activityBinding?.removeOnNewIntentListener(this)
        activityBinding = null
    }

    override fun onDetachedFromActivityForConfigChanges() {
        onDetachedFromActivity()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }
}

class AutofillServicePlugin : FlutterPlugin, ActivityAware {

    private var impl: AutofillServicePluginImpl? = null
    private var channel: MethodChannel? = null
    private var legacyChannel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val channel = MethodChannel(binding.binaryMessenger, "com.moshinop.autofill_service")
        val legacy = MethodChannel(binding.binaryMessenger, "codeux.design/autofill_service")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            impl = AutofillServicePluginImpl(binding.applicationContext).apply {
                this.channel = channel
            }
            channel.setMethodCallHandler(impl)
            legacy.setMethodCallHandler(impl)
            AutofillServicePluginImpl.cleanupExpiredPendingSaveData(binding.applicationContext)
            AutofillServicePluginImpl.schedulePendingSaveCleanup(binding.applicationContext)
        } else {
            val fallbackHandler = MethodChannel.MethodCallHandler { call, result ->
                when (call.method) {
                    "hasAutofillServicesSupport" -> result.success(false)
                    "hasEnabledAutofillServices" -> result.success(null)
                    else -> result.notImplemented()
                }
            }
            channel.setMethodCallHandler(fallbackHandler)
            legacy.setMethodCallHandler(fallbackHandler)
        }
        this.channel = channel
        this.legacyChannel = legacy
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        legacyChannel?.setMethodCallHandler(null)
        channel = null
        legacyChannel = null
        impl = null
    }

    @SuppressLint("NewApi")
    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        impl?.onAttachedToActivity(binding)
    }

    @SuppressLint("NewApi")
    override fun onDetachedFromActivityForConfigChanges() {
        impl?.onDetachedFromActivityForConfigChanges()
    }

    @SuppressLint("NewApi")
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        impl?.onReattachedToActivityForConfigChanges(binding)
    }

    @SuppressLint("NewApi")
    override fun onDetachedFromActivity() {
        impl?.onDetachedFromActivity()
    }
}

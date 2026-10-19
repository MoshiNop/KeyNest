package com.moshinop.autofill_service

import android.annotation.TargetApi
import android.app.assist.AssistStructure
import android.os.*
import android.view.*
import android.view.autofill.AutofillId
import androidx.annotation.RequiresApi
import mu.KotlinLogging
import org.json.JSONObject

private val logger = KotlinLogging.logger {}

data class WebDomain(val scheme: String?, val domain: String) {
    fun toMap() = mapOf(
        SCHEME to scheme,
        DOMAIN to domain,
    )

    companion object {
        private const val SCHEME = "scheme"
        private const val DOMAIN = "domain"

        fun fromJson(obj: JSONObject) =
            WebDomain(
                scheme = obj.optString(SCHEME),
                domain = obj.optString(DOMAIN, ""),
            )
    }
}

@RequiresApi(Build.VERSION_CODES.O)
class AssistStructureParser(structure: AssistStructure) {

    val autoFillIds = mutableListOf<AutofillId>()
    val allNodes = mutableListOf<AssistStructure.ViewNode>()

    var primaryPackageName: String? = null
    var packageName = LinkedHashSet<String>()
    var webDomain = HashSet<WebDomain>()

    val fieldIds = mutableMapOf<AutofillInputType, MutableList<MatchedField>>()

    init {
        // Robust target package resolution directly from activity component
        structure.activityComponent?.packageName?.let { pkg ->
            if (pkg.isNotBlank() && pkg != "android") {
                primaryPackageName = pkg
                packageName.add(pkg)
            }
        }
        traverseStructure(structure)
    }

    fun getTargetPackage(): String {
        if (!primaryPackageName.isNullOrBlank() && primaryPackageName != "android") {
            return primaryPackageName!!
        }
        return packageName.firstOrNull { it.isNotBlank() && it != "android" }
            ?: primaryPackageName
            ?: packageName.firstOrNull()
            ?: ""
    }

    fun getPrimaryWebDomain(): String? {
        // Prioritize domain from the node containing password, username or email
        for (type in listOf(AutofillInputType.Password, AutofillInputType.NewPassword, AutofillInputType.UserName, AutofillInputType.Email)) {
            val matched = fieldIds[type]?.firstOrNull()
            if (matched != null) {
                val node = allNodes.firstOrNull { it.autofillId == matched.autofillId }
                if (node?.webDomain != null && node.webDomain!!.isNotBlank()) {
                    val sanitized = sanitizeWebDomain(node.webDomain)
                    if (sanitized != null) return sanitized
                }
            }
        }
        return webDomain.firstNotNullOfOrNull { sanitizeWebDomain(it.domain) }
    }

    private fun traverseStructure(structure: AssistStructure) {
        val windowNodes: List<AssistStructure.WindowNode> =
            structure.run {
                (0 until windowNodeCount).map { getWindowNodeAt(it) }
            }

        logger.debug { "Traversing windowNodes $windowNodes" }
        windowNodes.forEach { windowNode: AssistStructure.WindowNode ->
            windowNode.rootViewNode?.let { traverseNode(it, null) }
        }
    }

    private fun Any.debugToString(): String =
        when (this) {
            is Array<*> -> this.contentDeepToString()
            is Bundle -> keySet().map {
                it to get(it)?.toString()
            }.toString()
            is ViewStructure.HtmlInfo -> "HtmlInfo{<$tag ${attributes?.joinToString(" ") { "${it.first}=\"${it.second}\"" }}>}"
            else -> this.toString()
        }

    @TargetApi(Build.VERSION_CODES.O)
    private fun traverseNode(viewNode: AssistStructure.ViewNode, parentNode: AssistStructure.ViewNode? = null) {
        allNodes.add(viewNode)

        viewNode.autofillId?.let { autoFillIds.add(it) }

        viewNode.idPackage?.let { idPackage ->
            if (idPackage.isNotBlank() && idPackage != "android") {
                if (primaryPackageName.isNullOrBlank()) {
                    primaryPackageName = idPackage
                }
                packageName.add(idPackage)
            } else if (idPackage.isNotBlank()) {
                packageName.add(idPackage)
            }
        }
        viewNode.webDomain?.let { myWebDomain ->
            val cleanDomain = sanitizeWebDomain(myWebDomain)
            if (cleanDomain != null) {
                webDomain.add(
                    WebDomain(
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                            viewNode.webScheme
                        } else {
                            null
                        }, cleanDomain
                    )
                )
            }
        }
        viewNode.autofillId?.let { autofillId ->
            val isVisible = viewNode.visibility == View.VISIBLE
            val notExcluded = !isExcluded(viewNode)
            val isInputCandidate = viewNode.autofillType != View.AUTOFILL_TYPE_NONE ||
                    viewNode.inputType != 0 ||
                    !viewNode.autofillHints.isNullOrEmpty() ||
                    viewNode.className?.contains("Edit", ignoreCase = true) == true ||
                    viewNode.className?.contains("TextField", ignoreCase = true) == true ||
                    viewNode.isFocused

            if (isVisible && notExcluded && isInputCandidate) {
                AutofillInputType.values().forEach { type ->
                    fieldIds.getOrPut(type) { mutableListOf() }.addAll(
                        type.heuristics
                            .filter { it.predicate(viewNode, parentNode ?: viewNode) }
                            .map { MatchedField(it, autofillId) }
                    )
                }
            }
        }

        val children: List<AssistStructure.ViewNode>? =
            viewNode.run {
                (0 until childCount).map { getChildAt(it) }
            }

        children?.forEach { childNode: AssistStructure.ViewNode ->
            traverseNode(childNode, viewNode)
        }
    }

    private fun isExcluded(viewNode: AssistStructure.ViewNode): Boolean {
        val id = viewNode.idEntry?.lowercase() ?: ""
        val hint = viewNode.hint?.lowercase() ?: ""
        val desc = viewNode.contentDescription?.toString()?.lowercase() ?: ""
        val hints = viewNode.autofillHints?.joinToString(" ")?.lowercase() ?: ""
        val combined = "$id $hint $desc $hints"

        // Never exclude if it explicitly looks like an email, username, or password field
        val isLoginField = combined.contains("email") || combined.contains("mail") ||
                combined.contains("user") || combined.contains("login") ||
                combined.contains("pass") || combined.contains("pwd") ||
                combined.contains("ইমেইল") || combined.contains("পাসওয়ার্ড")
        if (isLoginField) return false

        return EXCLUDED_KEYWORDS.any { combined.contains(it) }
    }

    fun isTrustedBrowser(): Boolean {
        return packageName.any { isBrowserPackage(it) }
    }

    companion object {
        val TRUSTED_BROWSERS = setOf(
            "com.android.chrome",
            "com.chrome.beta",
            "com.chrome.dev",
            "com.chrome.canary",
            "com.google.android.apps.chrome",
            "org.mozilla.firefox",
            "org.mozilla.firefox_beta",
            "org.mozilla.fenix",
            "org.mozilla.focus",
            "com.microsoft.emmx",
            "com.brave.browser",
            "com.brave.browser_nightly",
            "com.brave.browser_beta",
            "com.sec.android.app.sbrowser",
            "com.sec.android.app.sbrowser.beta",
            "com.opera.browser",
            "com.opera.browser.beta",
            "com.opera.mini.native",
            "com.opera.touch",
            "com.opera.gx",
            "com.duckduckgo.mobile.android",
            "com.vivaldi.browser",
            "com.vivaldi.browser.snapshot",
            "com.kiwibrowser.browser",
            "com.mi.globalbrowser",
            "com.android.browser",
            "com.huawei.browser",
            "com.torproject.torbrowser",
            "mark.via.gp",
            "io.github.forkmaintainers.iceraven"
        )

        fun isBrowserPackage(pkg: String): Boolean {
            val clean = pkg.trim().lowercase()
            if (clean.isEmpty()) return false
            if (TRUSTED_BROWSERS.contains(clean)) return true
            return clean.endsWith(".browser") ||
                    clean.contains("chrome") ||
                    clean.contains("firefox") ||
                    clean.contains("browser") ||
                    clean.contains("fenix")
        }

        fun sanitizeWebDomain(raw: String?): String? {
            if (raw.isNullOrBlank()) return null
            var trimmed = raw.trim().lowercase()
            if (trimmed.startsWith("http://")) trimmed = trimmed.substring(7)
            else if (trimmed.startsWith("https://")) trimmed = trimmed.substring(8)
            // Strip userinfo if present
            if (trimmed.contains("@")) trimmed = trimmed.substringAfterLast("@")
            // Strip path, query, hash
            trimmed = trimmed.substringBefore("/").substringBefore("?").substringBefore("#")
            // Strip port if present
            if (trimmed.contains(":") && !trimmed.contains("]")) {
                trimmed = trimmed.substringBefore(":")
            }
            trimmed = trimmed.trim('.').trim()
            return trimmed.ifBlank { null }
        }

        private val EXCLUDED_KEYWORDS = listOf(
            "search", "coupon", "promo", "captcha", "comment", "address", "zip",
            "সার্চ", "খুঁজুন", "কুপন", "ঠিকানা"
        )
    }

    override fun toString(): String {
        return "AssistStructureParser(autoFillIds=$autoFillIds, packageName=$packageName, webDomain=$webDomain, fieldIds=$fieldIds)"
    }
}
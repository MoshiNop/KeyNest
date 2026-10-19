package com.moshinop.autofill_service

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.net.Uri
import android.os.ParcelFileDescriptor
import androidx.core.content.res.ResourcesCompat
import java.io.ByteArrayOutputStream
import java.io.FileNotFoundException

class AutofillLockStateProvider : ContentProvider() {

    override fun onCreate(): Boolean {
        return true
    }

    override fun getType(uri: Uri): String {
        return "image/png"
    }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?
    ): Cursor? = null

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = 0
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor? {
        val path = uri.lastPathSegment ?: throw FileNotFoundException("Invalid uri: $uri")
        val ctx = context ?: throw FileNotFoundException("Context is null")

        val bytes = getBytesForPath(ctx, path)
            ?: throw FileNotFoundException("Resource not found: $path")

        return openPipeHelper(uri, "image/png", null, bytes) { output, _, _, _, data ->
            try {
                java.io.FileOutputStream(output.fileDescriptor).use { fos ->
                    fos.write(data)
                    fos.flush()
                }
            } catch (_: Exception) {
            }
        }
    }

    companion object {
        private var actionLockPng: ByteArray? = null
        private var fallbackLockPng: ByteArray? = null
        private var personPng: ByteArray? = null
        private var totpPng: ByteArray? = null
        private var transparentPng: ByteArray? = null

        fun getLockUri(packageName: String): Uri {
            return Uri.parse("content://$packageName.autofill_lock_state/action_lock.png")
        }

        fun getFallbackIconUri(packageName: String): Uri {
            return Uri.parse("content://$packageName.autofill_lock_state/fallback_icon.png")
        }

        fun getFallbackTotpUri(packageName: String): Uri {
            return Uri.parse("content://$packageName.autofill_lock_state/fallback_totp.png")
        }

        private fun getTransparentPng(): ByteArray {
            transparentPng?.let { return it }
            val bitmap = Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888)
            bitmap.eraseColor(Color.TRANSPARENT)
            val stream = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
            val bytes = stream.toByteArray()
            transparentPng = bytes
            return bytes
        }

        private fun drawableToPng(context: Context, drawableResId: Int, sizeDp: Int = 24): ByteArray {
            val density = context.resources.displayMetrics.density
            val px = (sizeDp * density).toInt().coerceAtLeast(1)
            val drawable = ResourcesCompat.getDrawable(context.resources, drawableResId, context.theme)
                ?: return ByteArray(0)
            val bitmap = Bitmap.createBitmap(px, px, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            drawable.setBounds(0, 0, px, px)
            drawable.draw(canvas)
            val stream = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
            return stream.toByteArray()
        }

        fun getBytesForPath(context: Context, path: String): ByteArray? {
            val isLocked = AutofillCredentialStore.isLocked
            return when (path) {
                "action_lock.png" -> {
                    if (isLocked) {
                        actionLockPng ?: drawableToPng(context, R.drawable.ic_lock_black_24dp, 16).also { actionLockPng = it }
                    } else {
                        getTransparentPng()
                    }
                }
                "fallback_icon.png" -> {
                    if (isLocked) {
                        fallbackLockPng ?: drawableToPng(context, R.drawable.ic_lock_black_24dp, 28).also { fallbackLockPng = it }
                    } else {
                        personPng ?: drawableToPng(context, R.drawable.ic_person_black_24dp, 28).also { personPng = it }
                    }
                }
                "fallback_totp.png" -> {
                    if (isLocked) {
                        fallbackLockPng ?: drawableToPng(context, R.drawable.ic_lock_black_24dp, 28).also { fallbackLockPng = it }
                    } else {
                        totpPng ?: drawableToPng(context, R.drawable.ic_totp_24dp, 28).also { totpPng = it }
                    }
                }
                else -> null
            }
        }
    }
}

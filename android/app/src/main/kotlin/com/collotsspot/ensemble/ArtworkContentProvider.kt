package com.collotsspot.ensemble

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.util.Base64
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/**
 * ContentProvider that serves artwork images to Android Auto.
 *
 * Android Auto only supports content:// and android.resource:// URIs for artwork.
 * This provider accepts a base64url-encoded HTTP URL in the path, downloads the
 * image (with disk caching), and returns a ParcelFileDescriptor.
 *
 * URI format: content://com.collotsspot.ensemble.artwork/{base64url_encoded_http_url}
 */
class ArtworkContentProvider : ContentProvider() {

    companion object {
        private const val CONNECT_TIMEOUT_MS = 5000
        private const val READ_TIMEOUT_MS = 10000
    }

    override fun onCreate(): Boolean = true

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor? {
        val encoded = uri.lastPathSegment ?: return null
        val httpUrl: String
        try {
            httpUrl = String(Base64.decode(encoded, Base64.URL_SAFE or Base64.NO_WRAP))
        } catch (e: Exception) {
            return null
        }

        val cacheDir = File(context?.cacheDir, "artwork")
        if (!cacheDir.exists()) cacheDir.mkdirs()

        val hash = md5(httpUrl)
        val cacheFile = File(cacheDir, hash)

        if (!cacheFile.exists()) {
            try {
                val connection = URL(httpUrl).openConnection() as HttpURLConnection
                connection.connectTimeout = CONNECT_TIMEOUT_MS
                connection.readTimeout = READ_TIMEOUT_MS
                connection.instanceFollowRedirects = true
                try {
                    connection.inputStream.use { input ->
                        cacheFile.outputStream().use { output ->
                            input.copyTo(output)
                        }
                    }
                } finally {
                    connection.disconnect()
                }
            } catch (e: Exception) {
                cacheFile.delete()
                return null
            }
        }

        return ParcelFileDescriptor.open(cacheFile, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun query(uri: Uri, projection: Array<String>?, selection: String?,
                       selectionArgs: Array<String>?, sortOrder: String?): Cursor? = null
    override fun getType(uri: Uri): String = "image/*"
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<String>?): Int = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?,
                        selectionArgs: Array<String>?): Int = 0

    private fun md5(input: String): String {
        val digest = MessageDigest.getInstance("MD5")
        val bytes = digest.digest(input.toByteArray())
        return bytes.joinToString("") { "%02x".format(it) }
    }
}

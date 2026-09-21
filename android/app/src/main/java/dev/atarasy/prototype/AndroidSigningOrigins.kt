package dev.atarasy.prototype

import android.content.Context
import android.content.pm.PackageManager
import java.security.MessageDigest
import java.util.Base64

object AndroidSigningOrigins {
    @Suppress("DEPRECATION")
    fun current(context: Context): Set<String> {
        val info = context.packageManager.getPackageInfo(context.packageName, PackageManager.GET_SIGNING_CERTIFICATES)
        val certificates = info.signingInfo?.apkContentsSigners?.map { it.toByteArray() } ?: emptyList()
        return fromCertificates(certificates)
    }

    internal fun fromCertificates(certificates: List<ByteArray>): Set<String> {
        require(certificates.isNotEmpty() && certificates.size <= 8)
        return certificates.map { certificate ->
            val digest = MessageDigest.getInstance("SHA-256").digest(certificate)
            "android:apk-key-hash:" + Base64.getUrlEncoder().withoutPadding().encodeToString(digest)
        }.toSortedSet().also { require(it.size == certificates.size && it.all { origin -> Regex("^android:apk-key-hash:[A-Za-z0-9_-]{43}$").matches(origin) }) }
    }
}

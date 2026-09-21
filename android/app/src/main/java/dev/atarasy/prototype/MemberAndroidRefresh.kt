package dev.atarasy.prototype

import android.content.Context
import com.google.firebase.FirebaseApp
import com.google.firebase.installations.FirebaseInstallations
import com.google.firebase.messaging.FirebaseMessaging
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.coroutines.suspendCoroutine
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long

data class MemberAndroidRefreshSubscription(val profile: String, val active: Boolean, val updatedAt: Long?)

object MemberAndroidRefreshHint {
    const val PROFILE = "atarasy.member-refresh-hint.1"
    fun valid(data: Map<String, String>, hasNotification: Boolean) = !hasNotification && data == mapOf("profile" to PROFILE)
}

object MemberAndroidRefreshEvents {
    private val mutable = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    val events = mutable.asSharedFlow()
    internal fun received() { mutable.tryEmit(Unit) }
}

class AtarasyMessagingService : FirebaseMessagingService() {
    @Suppress("OVERRIDE_DEPRECATION")
    override fun onNewToken(token: String) {
        // This build registers the installation ID after member sign-in; bearer access is never restored here.
    }
    override fun onMessageReceived(message: RemoteMessage) {
        if (MemberAndroidRefreshHint.valid(message.data, message.notification != null)) MemberAndroidRefreshEvents.received()
    }
}

interface MemberRefreshRegistrationProvider { suspend fun installation(): String }

class FirebaseRefreshRegistrationProvider(private val context: Context) : MemberRefreshRegistrationProvider {
    override suspend fun installation(): String {
        if (FirebaseApp.getApps(context).isEmpty()) throw MemberFailure.Unavailable
        await(FirebaseMessaging.getInstance().register())
        return await(FirebaseInstallations.getInstance().id).also { if (!Regex("^[A-Za-z0-9_-]{20,128}$").matches(it)) throw MemberFailure.Malformed }
    }
    private suspend fun <T> await(task: com.google.android.gms.tasks.Task<T>): T = suspendCoroutine { continuation ->
        task.addOnCompleteListener { completed -> if (completed.isSuccessful) continuation.resume(completed.result) else continuation.resumeWithException(MemberFailure.Unavailable) }
    }
}

class MemberAndroidRefresh(private val sessions: MemberSessionClient, private val registrations: MemberRefreshRegistrationProvider) {
    suspend fun status(): MemberAndroidRefreshSubscription {
        val (reply, _) = sessions.readWithSession("/member/android-refresh"); return decode(reply)
    }
    suspend fun register(): MemberAndroidRefreshSubscription {
        val installation = registrations.installation(); val body = buildJsonObject { put("installation", JsonPrimitive(installation)) }.toString().toByteArray()
        val (reply, _) = sessions.readWithSession("/member/android-refresh/subscription", body = body); return decode(reply).also { if (!it.active) throw MemberFailure.ScopeMismatch }
    }
    suspend fun disable(): MemberAndroidRefreshSubscription {
        val (reply, _) = sessions.readWithSession("/member/android-refresh/disable", body = "{}".toByteArray()); return decode(reply).also { if (it.active) throw MemberFailure.ScopeMismatch }
    }
    private fun decode(reply: MemberHttpResponse): MemberAndroidRefreshSubscription {
        if (reply.status != 200) throw MemberFailure.Http(reply.status)
        if (reply.contentType?.substringBefore(';')?.trim()?.lowercase() != "application/json") throw MemberFailure.Malformed
        return try {
            val root = Json.parseToJsonElement(reply.body.toString(Charsets.UTF_8)).jsonObject
            require(root.keys == setOf("profile", "active", "updatedAt"))
            val profile = root.getValue("profile").jsonPrimitive.let { require(it.isString); it.content }
            val active = root.getValue("active").jsonPrimitive.let { require(!it.isString); it.content.toBooleanStrict() }
            val updated = root.getValue("updatedAt").takeUnless { it === JsonNull }?.jsonPrimitive?.let { require(!it.isString); it.long }.also { require(it == null || it in 0..Canonical.MAXIMUM_INTEGER) }
            require(profile == "atarasy.member-android-refresh-subscription.1" && (active == (updated != null)))
            MemberAndroidRefreshSubscription(profile, active, updated)
        } catch (failure: Exception) { if (failure is MemberFailure) throw failure else throw MemberFailure.Malformed }
    }
}

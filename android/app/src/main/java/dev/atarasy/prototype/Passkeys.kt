package dev.atarasy.prototype

import android.app.Activity
import androidx.credentials.CreateCredentialRequest
import androidx.credentials.CreateCredentialResponse
import androidx.credentials.CreatePublicKeyCredentialRequest
import androidx.credentials.CreatePublicKeyCredentialResponse
import androidx.credentials.CredentialManager
import androidx.credentials.GetCredentialRequest
import androidx.credentials.GetCredentialResponse
import androidx.credentials.GetPublicKeyCredentialOption
import androidx.credentials.PublicKeyCredential
import androidx.credentials.exceptions.CreateCredentialCancellationException
import androidx.credentials.exceptions.GetCredentialCancellationException
import androidx.credentials.exceptions.NoCredentialException

sealed interface PasskeyResult {
    data class Completed(val responseJson: String) : PasskeyResult
    data object Cancelled : PasskeyResult
    data object Unavailable : PasskeyResult
    data class Failed(val reason: String) : PasskeyResult
}

@JvmInline
value class ServerCeremonyJson private constructor(val exact: String) {
    companion object {
        fun from(value: String): ServerCeremonyJson {
            require(value.isNotEmpty() && value.toByteArray(Charsets.UTF_8).size <= 1_048_576)
            return ServerCeremonyJson(value)
        }
    }
}

interface PasskeyGateway {
    suspend fun create(request: CreateCredentialRequest): CreateCredentialResponse
    suspend fun get(request: GetCredentialRequest): GetCredentialResponse
}

class CredentialManagerGateway(private val activity: Activity) : PasskeyGateway {
    private val manager = CredentialManager.create(activity)
    override suspend fun create(request: CreateCredentialRequest) = manager.createCredential(activity, request)
    override suspend fun get(request: GetCredentialRequest) = manager.getCredential(activity, request)
}

/** Server ceremony JSON crosses this boundary byte for byte and is never reconstructed by the app. */
interface PasskeyAuthorizer { suspend fun authenticate(serverRequestJson: String): PasskeyResult }

class PasskeyCeremonies(private val gateway: PasskeyGateway) : PasskeyAuthorizer {
    suspend fun register(serverRequestJson: String): PasskeyResult = try {
        val request = ServerCeremonyJson.from(serverRequestJson)
        val response = gateway.create(CreatePublicKeyCredentialRequest(request.exact))
        val publicKey = response as? CreatePublicKeyCredentialResponse
            ?: return PasskeyResult.Failed("Unexpected credential response")
        PasskeyResult.Completed(publicKey.registrationResponseJson)
    } catch (_: CreateCredentialCancellationException) {
        PasskeyResult.Cancelled
    } catch (_: Exception) {
        PasskeyResult.Failed("Passkey registration unavailable")
    }

    override suspend fun authenticate(serverRequestJson: String): PasskeyResult = try {
        val request = ServerCeremonyJson.from(serverRequestJson)
        val response = gateway.get(GetCredentialRequest(listOf(GetPublicKeyCredentialOption(request.exact))))
        val publicKey = response.credential as? PublicKeyCredential
            ?: return PasskeyResult.Failed("Unexpected credential response")
        PasskeyResult.Completed(publicKey.authenticationResponseJson)
    } catch (_: GetCredentialCancellationException) {
        PasskeyResult.Cancelled
    } catch (_: NoCredentialException) {
        PasskeyResult.Unavailable
    } catch (_: Exception) {
        PasskeyResult.Failed("Passkey authentication unavailable")
    }
}

package dev.atarasy.prototype

import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.CookieHandler
import java.net.URL
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

data class MemberHttpRequest(
    val path: String,
    val query: List<Pair<String, String>> = emptyList(),
    val body: ByteArray? = null,
    val token: String? = null,
)

data class MemberHttpResponse(
    val requestedUrl: String,
    val responseUrl: String,
    val status: Int,
    val contentType: String?,
    val cacheControl: String?,
    val body: ByteArray,
)

interface MemberHttpTransport {
    suspend fun send(request: MemberHttpRequest): MemberHttpResponse
}

class UrlConnectionMemberHttpTransport internal constructor(
    private val environment: MemberEnvironment,
    private val timeoutMilliseconds: Int,
    private val maximumResponseBytes: Int,
    private val connectionFactory: (URL) -> HttpURLConnection,
) : MemberHttpTransport {
    constructor(environment: MemberEnvironment, timeoutMilliseconds: Int = 15_000, maximumResponseBytes: Int = 1_048_576) :
        this(environment, timeoutMilliseconds, maximumResponseBytes, { it.openConnection() as HttpURLConnection })
    init {
        require(timeoutMilliseconds in 1..60_000 && maximumResponseBytes in 1..16_777_216)
    }

    override suspend fun send(request: MemberHttpRequest): MemberHttpResponse = withContext(Dispatchers.IO) {
        require(Regex("^/[A-Za-z0-9_./-]+$").matches(request.path) && ".." !in request.path)
        require(request.query.size <= 32 && request.query.all { Regex("^[A-Za-z][A-Za-z0-9_]{0,63}$").matches(it.first) && it.second.toByteArray().size <= 2_048 })
        request.token?.let { require(Regex("^amr1_[A-Za-z0-9_-]{43}$").matches(it)) }
        require(CookieHandler.getDefault() == null)
        val requested = memberRequestUrl(environment, request.path, request.query)
        val connection = connectionFactory(URL(requested))
        try {
            connection.instanceFollowRedirects = false
            connection.useCaches = false
            connection.defaultUseCaches = false
            connection.connectTimeout = timeoutMilliseconds
            connection.readTimeout = timeoutMilliseconds
            connection.requestMethod = if (request.body == null) "GET" else "POST"
            connection.setRequestProperty("Accept", "application/json")
            connection.setRequestProperty("Cache-Control", "no-store")
            request.token?.let { connection.setRequestProperty("Authorization", "Bearer $it") }
            request.body?.let { body ->
                require(body.size <= 1_048_576)
                connection.doOutput = true
                connection.setRequestProperty("Content-Type", "application/json")
                connection.setFixedLengthStreamingMode(body.size)
                connection.outputStream.use { it.write(body) }
            }
            val status = connection.responseCode
            val declaredLength = connection.getHeaderFieldLong("Content-Length", -1)
            require(declaredLength <= maximumResponseBytes)
            val source = if (status >= 400) connection.errorStream else connection.inputStream
            val responseBody = if (source == null) ByteArray(0) else source.use { input ->
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(8_192)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    require(output.size() + count <= maximumResponseBytes)
                    output.write(buffer, 0, count)
                }
                output.toByteArray()
            }
            MemberHttpResponse(
                requestedUrl = requested,
                responseUrl = connection.url.toString(),
                status = status,
                contentType = connection.getHeaderField("Content-Type"),
                cacheControl = connection.getHeaderField("Cache-Control"),
                body = responseBody,
            )
        } finally {
            connection.disconnect()
        }
    }
}

internal fun memberRequestUrl(environment: MemberEnvironment, path: String, query: List<Pair<String, String>>): String {
    if (query.isEmpty()) return environment.origin + path
    fun encode(value: String) = buildString {
        val allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".map { it.code }.toSet()
        value.toByteArray(Charsets.UTF_8).forEach { byte ->
            val unsigned = byte.toInt() and 0xff
            if (unsigned in allowed) append(unsigned.toChar()) else append("%%%02X".format(unsigned))
        }
    }
    return environment.origin + path + "?" + query.joinToString("&") { "${encode(it.first)}=${encode(it.second)}" }
}

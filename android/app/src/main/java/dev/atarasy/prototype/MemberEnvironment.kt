package dev.atarasy.prototype

import java.net.URI

class MemberEnvironment private constructor(val name: String, val origin: String, val relyingPartyId: String) {
    companion object {
        fun create(name: String, origin: String): MemberEnvironment {
            require(Regex("^[A-Za-z0-9_-]+$").matches(name))
            val uri = URI(origin)
            require(uri.scheme == "https" && !uri.host.isNullOrEmpty() && uri.userInfo == null && uri.query == null && uri.fragment == null)
            require(uri.path.isNullOrEmpty() || uri.path == "/")
            val port = if (uri.port == 443) -1 else uri.port
            val canonical = URI("https", null, uri.host, port, null, null, null).toASCIIString()
            return MemberEnvironment(name, canonical, uri.host)
        }

        val development = create("development", "https://api-dev.vox.delivery")
    }
}

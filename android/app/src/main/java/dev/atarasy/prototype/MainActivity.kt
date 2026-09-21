package dev.atarasy.prototype

import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.lifecycle.lifecycleScope
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Card
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import java.io.File

class MainActivity : ComponentActivity() {
    private lateinit var memberSessions: MemberSessionClient
    private lateinit var passkeys: PasskeyCeremonies
    private lateinit var authentication: MemberAuthenticationFlow

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val environment = MemberEnvironment.development
        val sessionDirectory = File(noBackupFilesDir, "member-sessions")
        memberSessions = MemberSessionClient(
            environment,
            UrlConnectionMemberHttpTransport(environment),
            EncryptedFileSessionVault(sessionDirectory, AndroidInstallationCipher()),
        )
        passkeys = PasskeyCeremonies(CredentialManagerGateway(this))
        authentication = MemberAuthenticationFlow(memberSessions, passkeys)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        setContent { AtarasyApp(onSignIn = authentication::signIn, onRegister = authentication::register) }
    }

    override fun onStop() {
        lifecycleScope.launch { memberSessions.lockLocalAccess() }
        super.onStop()
    }
}

@Composable
fun AtarasyApp(
    onSignIn: suspend () -> MemberAuthenticationResult = { MemberAuthenticationResult.Failed(MemberFailure.Unavailable) },
    onRegister: suspend (String) -> MemberAuthenticationResult = { MemberAuthenticationResult.Failed(MemberFailure.Unavailable) },
) {
    var selectedSection by rememberSaveable { mutableStateOf("Offers") }
    MaterialTheme {
        Surface(color = Color(0xFFF7F7F2), modifier = Modifier.fillMaxSize()) {
            Row(modifier = Modifier.fillMaxSize(), horizontalArrangement = Arrangement.Center) {
                Column(
                    modifier = Modifier.widthIn(max = 840.dp).fillMaxWidth().verticalScroll(rememberScrollState()).padding(24.dp),
                    verticalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    Text("Atarasy", style = MaterialTheme.typography.headlineLarge, modifier = Modifier.semantics { heading() })
                    Text("Your household", style = MaterialTheme.typography.titleMedium)
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        listOf("Offers", "Account").forEach { section ->
                            TextButton(onClick = { selectedSection = section }) { Text(section) }
                        }
                    }
                    Spacer(Modifier.height(8.dp))
                    if (selectedSection == "Offers") {
                        MemberCard("No offers waiting", "New offers and boxes that need your decision will appear here.")
                    } else {
                        MemberAccountCard(onSignIn, onRegister)
                    }
                }
            }
        }
    }
}

@Composable
private fun MemberAccountCard(
    onSignIn: suspend () -> MemberAuthenticationResult,
    onRegister: suspend (String) -> MemberAuthenticationResult,
) {
    var invitation by remember { mutableStateOf("") }
    var status by remember { mutableStateOf("Connect this device before viewing private household information.") }
    var busy by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    fun describe(result: MemberAuthenticationResult): String = when (result) {
        is MemberAuthenticationResult.SignedIn -> "Connected. Your private household information is ready."
        MemberAuthenticationResult.Registered -> "Device connected. Sign in to continue."
        MemberAuthenticationResult.Cancelled -> "Nothing changed."
        MemberAuthenticationResult.NoCredential -> "No passkey is available for this account."
        is MemberAuthenticationResult.Failed -> "The account could not be connected. Try again."
    }
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("Account", style = MaterialTheme.typography.titleLarge)
            Text(status, style = MaterialTheme.typography.bodyLarge)
            Button(enabled = !busy, onClick = {
                busy = true; scope.launch { status = describe(onSignIn()); busy = false }
            }) { Text(if (busy) "Connecting…" else "Sign in with passkey") }
            OutlinedTextField(
                value = invitation,
                onValueChange = { invitation = it.trim() },
                enabled = !busy,
                label = { Text("Device invitation") },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                modifier = Modifier.fillMaxWidth(),
            )
            Button(enabled = !busy && Regex("^aen1_[A-Za-z0-9_-]{43}$").matches(invitation), onClick = {
                val submitted = invitation; invitation = ""; busy = true
                scope.launch { status = describe(onRegister(submitted)); busy = false }
            }) { Text("Connect this device") }
        }
    }
}

@Composable
private fun MemberCard(title: String, detail: String) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(title, style = MaterialTheme.typography.titleLarge)
            Text(detail, style = MaterialTheme.typography.bodyLarge)
        }
    }
}

package dev.atarasy.prototype

import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
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
import androidx.compose.ui.text.font.FontWeight
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import java.io.File

class MainActivity : ComponentActivity() {
    private lateinit var memberSessions: MemberSessionClient
    private lateinit var passkeys: PasskeyCeremonies
    private lateinit var authentication: MemberAuthenticationFlow
    private lateinit var offers: MemberOffers

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
        offers = MemberOffers(memberSessions)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        setContent {
            AtarasyApp(
                onSignIn = authentication::signIn,
                onRegister = authentication::register,
                onLoadOffers = offers::listAll,
                onLoadDetail = offers::detail,
            )
        }
    }

    override fun onStop() {
        lifecycleScope.launch(start = CoroutineStart.UNDISPATCHED) { memberSessions.lockLocalAccess() }
        super.onStop()
    }
}

@Composable
fun AtarasyApp(
    onSignIn: suspend () -> MemberAuthenticationResult = { MemberAuthenticationResult.Failed(MemberFailure.Unavailable) },
    onRegister: suspend (String) -> MemberAuthenticationResult = { MemberAuthenticationResult.Failed(MemberFailure.Unavailable) },
    onLoadOffers: suspend (MemberSessionInfo) -> List<MemberOfferSummary> = { throw MemberFailure.Unavailable },
    onLoadDetail: suspend (MemberOfferSummary) -> MemberOfferDetail = { throw MemberFailure.Unavailable },
) {
    var selectedSection by rememberSaveable { mutableStateOf("Offers") }
    var session by remember { mutableStateOf<MemberSessionInfo?>(null) }
    var offers by remember { mutableStateOf<List<MemberOfferSummary>?>(null) }
    var offerFailure by remember { mutableStateOf(false) }
    var selectedOffer by remember { mutableStateOf<MemberOfferSummary?>(null) }
    var detail by remember { mutableStateOf<MemberOfferDetail?>(null) }
    var detailFailure by remember { mutableStateOf(false) }
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_STOP) {
                session = null; offers = null; selectedOffer = null; detail = null
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }
    LaunchedEffect(session) {
        val current = session ?: run { offers = null; return@LaunchedEffect }
        offers = null; offerFailure = false; selectedOffer = null; detail = null
        try { offers = onLoadOffers(current) } catch (failure: Exception) {
            if (failure is CancellationException) throw failure
            offerFailure = true
        }
    }
    LaunchedEffect(selectedOffer, session) {
        val selected = selectedOffer ?: run { detail = null; return@LaunchedEffect }
        if (session == null) return@LaunchedEffect
        detail = null; detailFailure = false
        try { detail = onLoadDetail(selected) } catch (failure: Exception) {
            if (failure is CancellationException) throw failure
            detailFailure = true
        }
    }
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
                        MemberOffersCard(
                            connected = session != null,
                            offers = offers,
                            failed = offerFailure,
                            selectedOffer = selectedOffer,
                            detail = detail,
                            detailFailed = detailFailure,
                            onSelect = { selectedOffer = it },
                            onAccount = { selectedSection = "Account" },
                        )
                    } else {
                        MemberAccountCard(
                            onSignIn = onSignIn,
                            onRegister = onRegister,
                            onSignedIn = { session = it; selectedSection = "Offers" },
                        )
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
    onSignedIn: (MemberSessionInfo) -> Unit,
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
                busy = true; scope.launch {
                    val result = onSignIn(); status = describe(result)
                    if (result is MemberAuthenticationResult.SignedIn) onSignedIn(result.session)
                    busy = false
                }
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
private fun MemberOffersCard(
    connected: Boolean,
    offers: List<MemberOfferSummary>?,
    failed: Boolean,
    selectedOffer: MemberOfferSummary?,
    detail: MemberOfferDetail?,
    detailFailed: Boolean,
    onSelect: (MemberOfferSummary?) -> Unit,
    onAccount: () -> Unit,
) {
    when {
        !connected -> MemberCard("Connect your account", "Sign in with your passkey before viewing private offers.") {
            Button(onClick = onAccount) { Text("Go to Account") }
        }
        failed -> MemberCard("Offers are unavailable", "Your private offer list could not be loaded. Sign in again to retry.")
        offers == null -> MemberCard("Loading offers…", "Checking every presenter connected to your household.")
        selectedOffer != null -> MemberOfferDetailCard(detail, detailFailed) { onSelect(null) }
        offers.isEmpty() -> MemberCard("No offers waiting", "New offers and boxes that need your decision will appear here.")
        else -> Card(modifier = Modifier.fillMaxWidth()) {
            Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("Offers", style = MaterialTheme.typography.titleLarge)
                offers.forEach { offer ->
                    Card(modifier = Modifier.fillMaxWidth(), onClick = { onSelect(offer) }) {
                        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Text(if (offer.binding == "digital") "Digital offer" else "Box offer", fontWeight = FontWeight.SemiBold)
                            Text(offer.state.replaceFirstChar { it.uppercase() })
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun MemberOfferDetailCard(detail: MemberOfferDetail?, failed: Boolean, onBack: () -> Unit) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            TextButton(onClick = onBack) { Text("Back to offers") }
            when {
                failed -> { Text("Offer unavailable", style = MaterialTheme.typography.titleLarge); Text("This offer could not be loaded.") }
                detail == null -> { Text("Loading offer…", style = MaterialTheme.typography.titleLarge) }
                else -> {
                    Text(if (detail.binding == "digital") "Digital offer" else "Box offer", style = MaterialTheme.typography.titleLarge)
                    Text(detail.purpose.replaceFirstChar { it.uppercase() } + " · " + detail.state.replaceFirstChar { it.uppercase() })
                    detail.candidates.forEach { candidate ->
                        Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                            Text(candidate.product, fontWeight = FontWeight.SemiBold)
                            Text("${candidate.quantity} × ${candidate.unitPrice}")
                            Text("Made by ${candidate.maker}")
                        }
                    }
                    detail.disclosures.flatMap { it.items }.forEach { item ->
                        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Text(item.label, fontWeight = FontWeight.SemiBold)
                            Text(item.value)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun MemberCard(title: String, detail: String, content: @Composable (() -> Unit)? = null) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(title, style = MaterialTheme.typography.titleLarge)
            Text(detail, style = MaterialTheme.typography.bodyLarge)
            content?.invoke()
        }
    }
}

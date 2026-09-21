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
    private lateinit var reviews: MemberReviews
    private lateinit var decisions: MemberDigitalDecisionFlow
    private lateinit var statements: MemberStatementFlow

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val environment = MemberEnvironment.development
        val sessionDirectory = File(noBackupFilesDir, "member-sessions")
        val installationCipher = AndroidInstallationCipher()
        memberSessions = MemberSessionClient(
            environment,
            UrlConnectionMemberHttpTransport(environment),
            EncryptedFileSessionVault(sessionDirectory, installationCipher),
        )
        passkeys = PasskeyCeremonies(CredentialManagerGateway(this))
        authentication = MemberAuthenticationFlow(memberSessions, passkeys)
        offers = MemberOffers(memberSessions)
        reviews = MemberReviews(memberSessions)
        val operationStore = EncryptedFileMemberOperationStore(File(noBackupFilesDir, "member-operations"), environment, installationCipher)
        val decisionOperations = MemberDecisionOperations(
            environment, memberSessions, operationStore,
            acceptedOrigins = AndroidSigningOrigins.current(this),
        )
        decisions = MemberDigitalDecisionFlow(environment, memberSessions, decisionOperations, passkeys)
        val statementOperations = MemberStatementOperations(environment, memberSessions, operationStore, acceptedOrigins = AndroidSigningOrigins.current(this))
        statements = MemberStatementFlow(environment, memberSessions, statementOperations, passkeys)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        setContent {
            AtarasyApp(
                onSignIn = authentication::signIn,
                onRegister = authentication::register,
                onLoadOffers = offers::listAll,
                onLoadDetail = offers::detail,
                onLoadReview = reviews::load,
                onPrepareDecision = decisions::prepare,
                onApproveDecision = decisions::approve,
                onPrepareStatement = statements::prepare,
                onApproveStatement = statements::approve,
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
    onLoadReview: suspend (MemberOfferDetail) -> MemberReview = { throw MemberFailure.Unavailable },
    onPrepareDecision: suspend (MemberSessionInfo, MemberOfferDetail, MemberApproval, Map<String, MemberDigitalChoice>) -> MemberDecisionReview = { _, _, _, _ -> throw MemberFailure.Unavailable },
    onApproveDecision: suspend (MemberDecisionReview) -> MemberDecisionActionResult = { MemberDecisionActionResult.Failed(MemberFailure.Unavailable) },
    onPrepareStatement: suspend (MemberSessionInfo, MemberOfferDetail, MemberStatement, List<String>) -> MemberStatementReview = { _, _, _, _ -> throw MemberFailure.Unavailable },
    onApproveStatement: suspend (MemberStatementReview) -> MemberStatementActionResult = { MemberStatementActionResult.Failed(MemberFailure.Unavailable) },
) {
    var selectedSection by rememberSaveable { mutableStateOf("Offers") }
    var session by remember { mutableStateOf<MemberSessionInfo?>(null) }
    var offers by remember { mutableStateOf<List<MemberOfferSummary>?>(null) }
    var offerFailure by remember { mutableStateOf(false) }
    var selectedOffer by remember { mutableStateOf<MemberOfferSummary?>(null) }
    var detail by remember { mutableStateOf<MemberOfferDetail?>(null) }
    var detailFailure by remember { mutableStateOf(false) }
    var review by remember { mutableStateOf<MemberReview?>(null) }
    var reviewFailure by remember { mutableStateOf(false) }
    var refreshGeneration by remember { mutableStateOf(0L) }
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_STOP) {
                session = null; offers = null; selectedOffer = null; detail = null; review = null
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }
    LaunchedEffect(session, refreshGeneration) {
        val current = session ?: run { offers = null; return@LaunchedEffect }
        offers = null; offerFailure = false; selectedOffer = null; detail = null
        try { offers = onLoadOffers(current) } catch (failure: Exception) {
            if (failure is CancellationException) throw failure
            if (failure.endsPrivateSession()) session = null else offerFailure = true
        }
    }
    LaunchedEffect(selectedOffer, session) {
        val selected = selectedOffer ?: run { detail = null; review = null; return@LaunchedEffect }
        if (session == null) return@LaunchedEffect
        detail = null; detailFailure = false; review = null; reviewFailure = false
        try {
            val loaded = onLoadDetail(selected); detail = loaded
            review = onLoadReview(loaded)
        } catch (failure: Exception) {
            if (failure is CancellationException) throw failure
            if (failure.endsPrivateSession()) session = null
            else if (detail == null) detailFailure = true else reviewFailure = true
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
                            review = review,
                            reviewFailed = reviewFailure,
                            session = session,
                            onPrepareDecision = onPrepareDecision,
                            onApproveDecision = onApproveDecision,
                            onRecorded = { selectedOffer = null; offers = null; offerFailure = false; refreshGeneration++ },
                            onPrepareStatement = onPrepareStatement,
                            onApproveStatement = onApproveStatement,
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

private fun Exception.endsPrivateSession() = this is MemberFailure.Expired || this is MemberFailure.Superseded || (this is MemberFailure.Http && status == 401)

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
    review: MemberReview?,
    reviewFailed: Boolean,
    session: MemberSessionInfo?,
    onPrepareDecision: suspend (MemberSessionInfo, MemberOfferDetail, MemberApproval, Map<String, MemberDigitalChoice>) -> MemberDecisionReview,
    onApproveDecision: suspend (MemberDecisionReview) -> MemberDecisionActionResult,
    onRecorded: () -> Unit,
    onPrepareStatement: suspend (MemberSessionInfo, MemberOfferDetail, MemberStatement, List<String>) -> MemberStatementReview,
    onApproveStatement: suspend (MemberStatementReview) -> MemberStatementActionResult,
    onSelect: (MemberOfferSummary?) -> Unit,
    onAccount: () -> Unit,
) {
    when {
        !connected -> MemberCard("Connect your account", "Sign in with your passkey before viewing private offers.") {
            Button(onClick = onAccount) { Text("Go to Account") }
        }
        failed -> MemberCard("Offers are unavailable", "Your private offer list could not be loaded. Sign in again to retry.")
        offers == null -> MemberCard("Loading offers…", "Checking every presenter connected to your household.")
        selectedOffer != null -> MemberOfferDetailCard(detail, detailFailed, review, reviewFailed, session, onPrepareDecision, onApproveDecision, onPrepareStatement, onApproveStatement, onRecorded) { onSelect(null) }
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
private fun MemberOfferDetailCard(
    detail: MemberOfferDetail?,
    failed: Boolean,
    review: MemberReview?,
    reviewFailed: Boolean,
    session: MemberSessionInfo?,
    onPrepareDecision: suspend (MemberSessionInfo, MemberOfferDetail, MemberApproval, Map<String, MemberDigitalChoice>) -> MemberDecisionReview,
    onApproveDecision: suspend (MemberDecisionReview) -> MemberDecisionActionResult,
    onPrepareStatement: suspend (MemberSessionInfo, MemberOfferDetail, MemberStatement, List<String>) -> MemberStatementReview,
    onApproveStatement: suspend (MemberStatementReview) -> MemberStatementActionResult,
    onRecorded: () -> Unit,
    onBack: () -> Unit,
) {
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
                    when {
                        reviewFailed -> Text("The decision review is unavailable.")
                        review == null -> Text("Loading decision review…")
                        review is MemberReview.Approval -> {
                            Text("Before you decide", style = MaterialTheme.typography.titleMedium)
                            review.value.candidates.forEach { candidate ->
                                Text(candidate.argumentAgainst)
                                candidate.alternatives.forEach { Text("• $it") }
                            }
                            review.value.excluded.forEach { Text("Excluded: ${it.product} (${it.reason.replace('_', ' ')})") }
                            Text(review.value.carriage?.let { "Delivery: $it" } ?: "Delivery amount is not known yet.")
                            if (session != null && detail.state == "presented") MemberDigitalDecisionControls(session, detail, review.value, onPrepareDecision, onApproveDecision, onRecorded)
                        }
                        review is MemberReview.Statement -> {
                            Text("Statement", style = MaterialTheme.typography.titleMedium)
                            review.value.lines.forEach { Text("${it.product}: ${it.amount}${if (it.givenBy != null) " (gift)" else ""}") }
                            Text(review.value.carriage?.let { "Delivery: $it" } ?: "Delivery amount is not known yet.")
                            if (session != null && detail.state in setOf("decided", "expired")) MemberStatementControls(session, detail, review.value, onPrepareStatement, onApproveStatement, onRecorded)
                        }
                        review is MemberReview.Settlement -> {
                            Text("Settled", style = MaterialTheme.typography.titleMedium)
                            Text("Goods charged: ${review.value.charged}")
                            if (review.value.disputedAmount > 0) Text("Disputed: ${review.value.disputedAmount}")
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun MemberStatementControls(
    session: MemberSessionInfo,
    detail: MemberOfferDetail,
    statement: MemberStatement,
    onPrepare: suspend (MemberSessionInfo, MemberOfferDetail, MemberStatement, List<String>) -> MemberStatementReview,
    onApprove: suspend (MemberStatementReview) -> MemberStatementActionResult,
    onRecorded: () -> Unit,
) {
    var disputed by remember(detail.id) { mutableStateOf<Set<String>>(emptySet()) }
    var frozen by remember(detail.id) { mutableStateOf<MemberStatementReview?>(null) }
    var busy by remember(detail.id) { mutableStateOf(false) }
    var notice by remember(detail.id) { mutableStateOf("") }
    val scope = rememberCoroutineScope()
    statement.lines.filter { it.valence in setOf("consumed", "lost") }.forEach { line ->
        TextButton(enabled = !busy && frozen == null, onClick = { disputed = if (line.candidate in disputed) disputed - line.candidate else disputed + line.candidate }) {
            Text(if (line.candidate in disputed) "Disputed: ${line.product}" else "Dispute ${line.product}")
        }
    }
    if (frozen == null) {
        Button(enabled = !busy && statement.carriage != null, onClick = {
            busy = true; notice = ""; scope.launch {
                try { frozen = onPrepare(session, detail, statement, disputed.sorted()); notice = "Review the frozen statement before signing." }
                catch (_: Exception) { notice = "The statement could not be prepared. Refresh the offer before trying again." }
                busy = false
            }
        }) { Text(if (busy) "Preparing…" else "Review statement") }
    } else {
        val value = frozen!!
        Text("Goods: ${value.local.goodsCharged} · Disputed: ${value.local.disputedGoods} · Delivery: ${value.local.carriage}", fontWeight = FontWeight.SemiBold)
        Button(enabled = !busy, onClick = {
            busy = true; notice = ""; scope.launch {
                when (val result = onApprove(value)) {
                    is MemberStatementActionResult.Outcome -> when (result.value) {
                        is MemberStatementOutcome.Committed -> { notice = "Statement recorded."; onRecorded() }
                        is MemberStatementOutcome.SettledElsewhere -> { frozen = null; notice = "This box was settled by another confirmation. Review the saved result." }
                        is MemberStatementOutcome.Pending -> { frozen = null; notice = "The operation is ${result.value.state}. Check the saved result before another action." }
                        MemberStatementOutcome.Unresolved -> { frozen = null; notice = "The result is unresolved. Check the saved result; do not submit again." }
                    }
                    MemberStatementActionResult.Cancelled -> notice = "Signing cancelled. Nothing was submitted."
                    MemberStatementActionResult.NoCredential -> notice = "The required passkey is unavailable."
                    is MemberStatementActionResult.Failed -> { frozen = null; notice = "The statement could not be confirmed. Check the saved result before another action." }
                }
                busy = false
            }
        }) { Text(if (busy) "Signing…" else "Sign and submit statement") }
        TextButton(enabled = !busy, onClick = { frozen = null; notice = "Prepared statement kept in saved results." }) { Text("Close review") }
    }
    if (notice.isNotEmpty()) Text(notice)
}

@Composable
private fun MemberDigitalDecisionControls(
    session: MemberSessionInfo,
    detail: MemberOfferDetail,
    approval: MemberApproval,
    onPrepare: suspend (MemberSessionInfo, MemberOfferDetail, MemberApproval, Map<String, MemberDigitalChoice>) -> MemberDecisionReview,
    onApprove: suspend (MemberDecisionReview) -> MemberDecisionActionResult,
    onRecorded: () -> Unit,
) {
    var choices by remember(detail.id) { mutableStateOf<Map<String, MemberDigitalChoice>>(emptyMap()) }
    var frozen by remember(detail.id) { mutableStateOf<MemberDecisionReview?>(null) }
    var busy by remember(detail.id) { mutableStateOf(false) }
    var notice by remember(detail.id) { mutableStateOf("") }
    val scope = rememberCoroutineScope()
    approval.candidates.forEach { candidate ->
        Text(candidate.product, fontWeight = FontWeight.SemiBold)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(enabled = !busy && frozen == null, onClick = { choices = choices + (candidate.id to MemberDigitalChoice.KEEP) }) { Text(if (choices[candidate.id] == MemberDigitalChoice.KEEP) "Keeping" else "Keep") }
            Button(enabled = !busy && frozen == null, onClick = { choices = choices + (candidate.id to MemberDigitalChoice.DECLINE) }) { Text(if (choices[candidate.id] == MemberDigitalChoice.DECLINE) "Declining" else "Decline") }
        }
    }
    val complete = approval.candidates.isNotEmpty() && approval.candidates.all { choices[it.id] in setOf(MemberDigitalChoice.KEEP, MemberDigitalChoice.DECLINE) }
    if (frozen == null) {
        Button(enabled = !busy && complete && approval.carriage != null, onClick = {
            busy = true; notice = ""
            scope.launch {
                try { frozen = onPrepare(session, detail, approval, choices); notice = "Review the frozen total before signing." }
                catch (_: Exception) { notice = "The decision could not be prepared. Refresh the offer before trying again." }
                busy = false
            }
        }) { Text(if (busy) "Preparing…" else "Review decision") }
    } else {
        val value = frozen!!
        Text("Goods: ${value.frozen.goods} · Delivery: ${value.frozen.carriage} · Total: ${value.frozen.total}", fontWeight = FontWeight.SemiBold)
        Button(enabled = !busy, onClick = {
            busy = true; notice = ""
            scope.launch {
                when (val result = onApprove(value)) {
                    is MemberDecisionActionResult.Outcome -> when (result.value) {
                        is MemberDecisionOutcome.Recorded -> { notice = "Decision recorded."; onRecorded() }
                        is MemberDecisionOutcome.Pending -> { frozen = null; notice = "The operation is ${result.value.state}. Check the saved result before another action." }
                        MemberDecisionOutcome.Unresolved -> { frozen = null; notice = "The result is unresolved. Check the saved result; do not submit again." }
                    }
                    MemberDecisionActionResult.Cancelled -> notice = "Signing cancelled. Nothing was submitted."
                    MemberDecisionActionResult.NoCredential -> notice = "The required passkey is unavailable."
                    is MemberDecisionActionResult.Failed -> { frozen = null; notice = "Approval could not be confirmed. Check the saved result before another action." }
                }
                busy = false
            }
        }) { Text(if (busy) "Signing…" else "Sign and submit") }
        TextButton(enabled = !busy, onClick = { frozen = null; notice = "Prepared decision kept in saved results." }) { Text("Close review") }
    }
    if (notice.isNotEmpty()) Text(notice)
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

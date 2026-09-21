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
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow
import java.io.File

class MainActivity : ComponentActivity() {
    private lateinit var memberSessions: MemberSessionClient
    private lateinit var passkeys: PasskeyCeremonies
    private lateinit var authentication: MemberAuthenticationFlow
    private lateinit var offers: MemberOffers
    private lateinit var reviews: MemberReviews
    private lateinit var decisions: MemberDigitalDecisionFlow
    private lateinit var statements: MemberStatementFlow
    private lateinit var withdrawals: MemberWithdrawalFlow
    private lateinit var savedOperations: MemberSavedOperations
    private lateinit var operationActions: MemberOperationActions
    private lateinit var permissions: MemberPermissions
    private lateinit var dials: MemberDials
    private lateinit var dialsFlow: MemberDialsFlow
    private lateinit var privateNode: MemberPrivateNode
    private lateinit var recoveryFlow: MemberRecoveryFlow
    private var hostMoveFlow: MemberHostMoveFlow? = null
    private lateinit var androidRefresh: MemberAndroidRefresh

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
        val withdrawalOperations = MemberWithdrawalOperations(
            environment, memberSessions, operationStore, decisionOperations, acceptedOrigins = AndroidSigningOrigins.current(this),
        )
        withdrawals = MemberWithdrawalFlow(memberSessions, withdrawalOperations, passkeys)
        savedOperations = MemberSavedOperations(environment, memberSessions, operationStore, decisionOperations, statementOperations, withdrawalOperations)
        operationActions = MemberOperationActions(environment, memberSessions)
        permissions = MemberPermissions(memberSessions)
        dials = MemberDials(environment, memberSessions, acceptedOrigins = AndroidSigningOrigins.current(this))
        dialsFlow = MemberDialsFlow(dials, passkeys)
        privateNode = MemberPrivateNode(
            environment,
            MemberPrivateNodeRemote(memberSessions),
            EncryptedFilePrivateNodeKeyVault(File(noBackupFilesDir, "member-private-node-key"), installationCipher),
        )
        recoveryFlow = MemberRecoveryFlow(
            environment,
            MemberRecoveryService(environment, memberSessions, acceptedOrigins = AndroidSigningOrigins.current(this)),
            privateNode,
            passkeys,
            EncryptedFileRecoveryMaterialVault(File(noBackupFilesDir, "member-recovery-material"), installationCipher),
            getString(R.string.atarasy_recovery_notice_channel).trim().ifEmpty { null },
        )
        androidRefresh = MemberAndroidRefresh(memberSessions, FirebaseRefreshRegistrationProvider(this))
        val moveTarget = runCatching {
            val name = getString(R.string.atarasy_move_target_name).trim(); val origin = getString(R.string.atarasy_move_target_origin).trim()
            if (name.isEmpty() || origin.isEmpty()) null else MemberEnvironment.create(name, origin)
        }.getOrNull()?.takeIf { it.origin != environment.origin }
        if (moveTarget != null) {
            val targetSessions = MemberSessionClient(moveTarget, UrlConnectionMemberHttpTransport(moveTarget), EncryptedFileSessionVault(sessionDirectory, installationCipher))
            val targetNode = MemberPrivateNode(moveTarget, MemberPrivateNodeRemote(targetSessions), EncryptedFilePrivateNodeKeyVault(File(noBackupFilesDir, "member-private-node-key"), installationCipher))
            hostMoveFlow = MemberHostMoveFlow(
                moveTarget,
                MemberHostMoveService(environment, memberSessions, acceptedOrigins = AndroidSigningOrigins.current(this)),
                MemberHostMoveService(moveTarget, targetSessions, acceptedOrigins = AndroidSigningOrigins.current(this)),
                targetSessions, privateNode, targetNode,
                offers, MemberOffers(targetSessions), reviews, MemberReviews(targetSessions), permissions, MemberPermissions(targetSessions), passkeys,
            )
        }
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
                onLoadSaved = savedOperations::list,
                onCheckSaved = savedOperations::check,
                onPrepareWithdrawal = withdrawals::prepare,
                onApproveWithdrawal = withdrawals::approve,
                onCancelOperation = operationActions::cancel,
                onLoadPermissions = permissions::list,
                onRevokePermission = permissions::revoke,
                onLoadPermissionRequests = permissions::requests,
                onReadPermissionRequest = permissions::request,
                onDecidePermissionRequest = permissions::decide,
                onLoadEffectiveMandates = dials::effective,
                onLoadMandateChanges = dials::changes,
                onPrepareMandateChange = dials::prepare,
                onPrepareMandateSignature = dials::prepareSignature,
                onApproveMandateChange = dialsFlow::approve,
                onCancelMandateChange = dials::cancel,
                onOpenPrivateNode = privateNode::open,
                recoveryCanConfigure = recoveryFlow.noticeChannel != null,
                onLoadRecovery = recoveryFlow::refresh,
                onRegisterRecoveryKey = recoveryFlow::registerRecoveryKey,
                onConfigureRecovery = recoveryFlow::configure,
                onBeginRecovery = recoveryFlow::beginLostDeviceRecovery,
                onApproveRecovery = recoveryFlow::approve,
                onFinishRecovery = recoveryFlow::finish,
                hostMoveAvailable = hostMoveFlow != null,
                onSetHostMoveSession = { hostMoveFlow?.setSession(it) },
                onPrepareHostMove = { hostMoveFlow?.prepare() ?: MemberHostMoveState(MemberHostMovePhase.SOURCE_RETAINED, "No trusted target host is configured.") },
                onRetireSourceHost = { hostMoveFlow?.retireSource() ?: MemberHostMoveState(MemberHostMovePhase.UNRESOLVED, "Source retirement is unavailable.") },
                onRegisterRefresh = androidRefresh::register,
                refreshEvents = MemberAndroidRefreshEvents.events,
            )
        }
    }

    override fun onStop() {
        lifecycleScope.launch(start = CoroutineStart.UNDISPATCHED) { hostMoveFlow?.lock(); privateNode.lock(); memberSessions.lockLocalAccess() }
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
    onLoadSaved: suspend (MemberSessionInfo) -> List<MemberOperationHandle> = { throw MemberFailure.Unavailable },
    onCheckSaved: suspend (MemberOperationHandle) -> MemberSavedResult = { throw MemberFailure.Unavailable },
    onPrepareWithdrawal: suspend (MemberSessionInfo, MemberOperationHandle) -> MemberWithdrawalReview = { _, _ -> throw MemberFailure.Unavailable },
    onApproveWithdrawal: suspend (MemberWithdrawalReview) -> MemberWithdrawalActionResult = { MemberWithdrawalActionResult.Failed(MemberFailure.Unavailable) },
    onCancelOperation: suspend (MemberOperationHandle) -> Unit = { throw MemberFailure.Unavailable },
    onLoadPermissions: suspend () -> MemberPermissionList = { throw MemberFailure.Unavailable },
    onRevokePermission: suspend (MemberPermission) -> MemberPermission = { throw MemberFailure.Unavailable },
    onLoadPermissionRequests: suspend () -> List<MemberPermissionRequest> = { throw MemberFailure.Unavailable },
    onReadPermissionRequest: suspend (String) -> MemberPermissionRequest = { throw MemberFailure.Unavailable },
    onDecidePermissionRequest: suspend (MemberPermissionRequest, Boolean) -> MemberPermissionRequest = { _, _ -> throw MemberFailure.Unavailable },
    onLoadEffectiveMandates: suspend () -> List<Mandate> = { throw MemberFailure.Unavailable },
    onLoadMandateChanges: suspend () -> List<MemberMandateChange> = { throw MemberFailure.Unavailable },
    onPrepareMandateChange: suspend (Mandate) -> PreparedMemberMandateChange = { throw MemberFailure.Unavailable },
    onPrepareMandateSignature: suspend (String) -> PreparedMemberMandateChange = { throw MemberFailure.Unavailable },
    onApproveMandateChange: suspend (PreparedMemberMandateChange) -> MemberDialsActionResult = { MemberDialsActionResult.Failed(MemberFailure.Unavailable) },
    onCancelMandateChange: suspend (String) -> MemberMandateChange = { throw MemberFailure.Unavailable },
    onOpenPrivateNode: suspend (MemberSessionInfo) -> MemberPrivateNodeState = { MemberPrivateNodeState.LOCKED },
    recoveryCanConfigure: Boolean = false,
    onLoadRecovery: suspend () -> MemberRecoverySnapshot = { throw MemberFailure.Unavailable },
    onRegisterRecoveryKey: suspend (MemberSessionInfo) -> MemberRecoveryActionResult = { MemberRecoveryActionResult.Failed(MemberFailure.Unavailable) },
    onConfigureRecovery: suspend (MemberSessionInfo, String) -> MemberRecoveryActionResult = { _, _ -> MemberRecoveryActionResult.Failed(MemberFailure.Unavailable) },
    onBeginRecovery: suspend (MemberSessionInfo) -> MemberRecoveryActionResult = { MemberRecoveryActionResult.Failed(MemberFailure.Unavailable) },
    onApproveRecovery: suspend (MemberSessionInfo, MemberRecoveryRequest) -> MemberRecoveryActionResult = { _, _ -> MemberRecoveryActionResult.Failed(MemberFailure.Unavailable) },
    onFinishRecovery: suspend (MemberSessionInfo, MemberRecoveryRequest) -> MemberRecoveryActionResult = { _, _ -> MemberRecoveryActionResult.Failed(MemberFailure.Unavailable) },
    hostMoveAvailable: Boolean = false,
    onSetHostMoveSession: (MemberSessionInfo?) -> Unit = {},
    onPrepareHostMove: suspend () -> MemberHostMoveState = { MemberHostMoveState(MemberHostMovePhase.SOURCE_RETAINED) },
    onRetireSourceHost: suspend () -> MemberHostMoveState = { MemberHostMoveState(MemberHostMovePhase.UNRESOLVED) },
    onRegisterRefresh: suspend () -> MemberAndroidRefreshSubscription = { throw MemberFailure.Unavailable },
    refreshEvents: Flow<Unit> = emptyFlow(),
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
    var privateNodeState by remember { mutableStateOf(MemberPrivateNodeState.LOCKED) }
    var refreshNotice by remember { mutableStateOf("") }
    var hintedRefresh by remember { mutableStateOf(false) }
    val accessSession = session?.takeIf { privateNodeState == MemberPrivateNodeState.READY }
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_STOP) {
                session = null; privateNodeState = MemberPrivateNodeState.LOCKED; offers = null; selectedOffer = null; detail = null; review = null
                onSetHostMoveSession(null)
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }
    LaunchedEffect(accessSession, refreshGeneration) {
        val current = accessSession ?: run { offers = null; return@LaunchedEffect }
        val retained = offers; val hinted = hintedRefresh
        if (!hinted) offers = null
        offerFailure = false; selectedOffer = null; detail = null
        try {
            offers = onLoadOffers(current)
            if (hinted) refreshNotice = "Configured sources were refreshed."
        } catch (failure: Exception) {
            if (failure is CancellationException) throw failure
            if (failure.endsPrivateSession()) session = null else offerFailure = true
            if (hinted) { offers = retained; offerFailure = retained == null; refreshNotice = "Some sources could not be checked. Cached rows remain stale." }
        }
        if (hinted) hintedRefresh = false
    }
    LaunchedEffect(refreshEvents) {
        refreshEvents.collect {
            if (session != null) {
                selectedOffer = null; detail = null; review = null; offerFailure = false; detailFailure = false; reviewFailure = false
                hintedRefresh = true; refreshNotice = "An update is available. Checking configured sources."; refreshGeneration++
            }
        }
    }
    LaunchedEffect(selectedOffer, accessSession) {
        val selected = selectedOffer ?: run { detail = null; review = null; return@LaunchedEffect }
        if (accessSession == null) return@LaunchedEffect
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
                    if (session != null && privateNodeState != MemberPrivateNodeState.READY) {
                        MemberCard(
                            if (privateNodeState == MemberPrivateNodeState.RECOVERY_REQUIRED) "Recovery required" else "Private records are locked",
                            if (privateNodeState == MemberPrivateNodeState.RECOVERY_REQUIRED) "This installation has no key for the encrypted private records. Protected actions remain closed." else "Open the encrypted private records before using protected actions.",
                        )
                    }
                    if (refreshNotice.isNotEmpty()) MemberCard("Updates", refreshNotice)
                    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        (listOf("Offers", "Saved", "Access", "Dials", "Recovery") + (if (hostMoveAvailable) listOf("Move Host") else emptyList()) + "Account").chunked(3).forEach { sections ->
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                sections.forEach { section -> TextButton(onClick = { selectedSection = section }) { Text(section) } }
                            }
                        }
                    }
                    Spacer(Modifier.height(8.dp))
                    if (selectedSection == "Offers") {
                        MemberOffersCard(
                            connected = accessSession != null,
                            offers = offers,
                            failed = offerFailure,
                            selectedOffer = selectedOffer,
                            detail = detail,
                            detailFailed = detailFailure,
                            review = review,
                            reviewFailed = reviewFailure,
                            session = accessSession,
                            onPrepareDecision = onPrepareDecision,
                            onApproveDecision = onApproveDecision,
                            onRecorded = { selectedOffer = null; offers = null; offerFailure = false; refreshGeneration++ },
                            onPrepareStatement = onPrepareStatement,
                            onApproveStatement = onApproveStatement,
                            onSelect = { selectedOffer = it },
                            onAccount = { selectedSection = "Account" },
                        )
                    } else if (selectedSection == "Saved") {
                        MemberSavedOperationsCard(accessSession, onLoadSaved, onCheckSaved, onPrepareWithdrawal, onApproveWithdrawal, onCancelOperation)
                    } else if (selectedSection == "Access") {
                        MemberPermissionsCard(accessSession, onLoadPermissions, onRevokePermission, onLoadPermissionRequests, onReadPermissionRequest, onDecidePermissionRequest)
                    } else if (selectedSection == "Dials") {
                        MemberDialsCard(accessSession, onLoadEffectiveMandates, onLoadMandateChanges, onPrepareMandateChange, onPrepareMandateSignature, onApproveMandateChange, onCancelMandateChange)
                    } else if (selectedSection == "Recovery") {
                        MemberRecoveryCard(
                            session, privateNodeState, recoveryCanConfigure, onLoadRecovery, onRegisterRecoveryKey, onConfigureRecovery,
                            onBeginRecovery, onApproveRecovery,
                            onFinish = { info, request -> onFinishRecovery(info, request).also { if (it is MemberRecoveryActionResult.Completed) privateNodeState = MemberPrivateNodeState.READY } },
                        )
                    } else if (selectedSection == "Move Host") {
                        MemberHostMoveCard(
                            accessSession, onPrepareHostMove,
                            onRetire = {
                                onRetireSourceHost().also {
                                    if (it.phase == MemberHostMovePhase.COMPLETED) {
                                        session = null; privateNodeState = MemberPrivateNodeState.LOCKED; onSetHostMoveSession(null); selectedSection = "Account"
                                    }
                                }
                            },
                        )
                    } else {
                        MemberAccountCard(
                            onSignIn = onSignIn,
                            onRegister = onRegister,
                            onSignedIn = { info ->
                                session = info; privateNodeState = onOpenPrivateNode(info)
                                onSetHostMoveSession(info)
                                refreshNotice = try {
                                    onRegisterRefresh(); "Private update notifications are enabled. Notifications contain no proposal details."
                                } catch (_: Exception) { "Update notifications are unavailable. Foreground refresh remains available." }
                                selectedSection = if (privateNodeState == MemberPrivateNodeState.READY) "Offers" else "Account"
                                privateNodeState
                            },
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun MemberHostMoveCard(
    session: MemberSessionInfo?,
    onPrepare: suspend () -> MemberHostMoveState,
    onRetire: suspend () -> MemberHostMoveState,
) {
    var state by remember(session) { mutableStateOf(MemberHostMoveState()) }
    var busy by remember(session) { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    fun run(action: suspend () -> MemberHostMoveState) {
        if (busy || session == null) return
        busy = true
        scope.launch {
            state = try { action() } catch (failure: Exception) {
                if (failure is CancellationException) throw failure
                state.copy(phase = MemberHostMovePhase.UNRESOLVED, notice = "The host move is unresolved. Source access has not been retired.")
            }
            busy = false
        }
    }
    when {
        session == null -> MemberCard("Host move is locked", "Sign in and open the encrypted private records before moving hosts.")
        else -> Card(modifier = Modifier.fillMaxWidth()) {
            Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("Move Host", style = MaterialTheme.typography.titleLarge)
                Text("Target", fontWeight = FontWeight.SemiBold)
                Text("The configured target host is trusted by this build. You will sign in there before anything is copied.")
                Text(state.phase.name.lowercase().replace('_', ' '), fontWeight = FontWeight.SemiBold)
                Text("Coverage", fontWeight = FontWeight.SemiBold)
                Text(state.coverage.ifEmpty { "Coverage has not been verified on the target host." })
                state.receipt?.let { Text("Receipt: ${it.archiveDigest}") }
                Text("Rollback", fontWeight = FontWeight.SemiBold)
                Text(if (state.phase == MemberHostMovePhase.READY_TO_RETIRE) "The target is verified. Source access remains active until the final signed retirement." else "A failed or interrupted import does not retire source access.")
                Button(
                    enabled = !busy && state.phase !in setOf(MemberHostMovePhase.READY_TO_RETIRE, MemberHostMovePhase.RETIRING, MemberHostMovePhase.COMPLETED),
                    onClick = { run(onPrepare) },
                ) { Text(if (busy) "Working…" else "Import and verify target") }
                if (state.phase == MemberHostMovePhase.READY_TO_RETIRE) {
                    Button(enabled = !busy, onClick = { run(onRetire) }) { Text(if (busy) "Retiring…" else "Retire source host access") }
                }
                if (state.notice.isNotEmpty()) Text(state.notice)
            }
        }
    }
}

@Composable
private fun MemberRecoveryCard(
    session: MemberSessionInfo?,
    privateNodeState: MemberPrivateNodeState,
    canConfigure: Boolean,
    onLoad: suspend () -> MemberRecoverySnapshot,
    onRegister: suspend (MemberSessionInfo) -> MemberRecoveryActionResult,
    onConfigure: suspend (MemberSessionInfo, String) -> MemberRecoveryActionResult,
    onBegin: suspend (MemberSessionInfo) -> MemberRecoveryActionResult,
    onApprove: suspend (MemberSessionInfo, MemberRecoveryRequest) -> MemberRecoveryActionResult,
    onFinish: suspend (MemberSessionInfo, MemberRecoveryRequest) -> MemberRecoveryActionResult,
) {
    var snapshot by remember(session) { mutableStateOf<MemberRecoverySnapshot?>(null) }
    var failed by remember(session) { mutableStateOf(false) }
    var busy by remember(session) { mutableStateOf(false) }
    var notice by remember(session) { mutableStateOf("") }
    var recoverer by remember(session) { mutableStateOf("") }
    var refresh by remember(session) { mutableStateOf(0L) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(session, refresh) {
        if (session == null) { snapshot = null; return@LaunchedEffect }
        failed = false
        try { snapshot = onLoad() } catch (failure: Exception) {
            if (failure is CancellationException) throw failure
            failed = true
        }
    }
    fun launchAction(block: suspend (MemberSessionInfo) -> MemberRecoveryActionResult) {
        val current = session ?: return
        if (busy) return
        busy = true; notice = ""
        scope.launch {
            val result = try { block(current) } catch (failure: Exception) {
                if (failure is CancellationException) throw failure
                MemberRecoveryActionResult.Failed(failure)
            }
            notice = when (result) {
                is MemberRecoveryActionResult.Completed -> result.notice
                MemberRecoveryActionResult.Cancelled -> "Recovery signing was cancelled. Nothing was submitted."
                MemberRecoveryActionResult.NoCredential -> "The required passkey is unavailable. Nothing was submitted."
                is MemberRecoveryActionResult.Failed -> "Recovery is not confirmed. Existing encrypted records were not replaced; current status is being refreshed."
            }
            busy = false; refresh++
        }
    }
    when {
        session == null -> MemberCard("Recovery is locked", "Sign in before checking or starting a recovery ceremony.")
        snapshot == null && failed -> MemberCard("Recovery status is unavailable", "Refresh before starting or approving a recovery ceremony.") {
            TextButton(enabled = !busy, onClick = { refresh++ }) { Text("Refresh recovery status") }
        }
        snapshot == null -> MemberCard("Checking recovery…", "Reading the recovery policy and ceremony log.")
        else -> Card(modifier = Modifier.fillMaxWidth()) {
            val current = snapshot!!
            Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("Recovery", style = MaterialTheme.typography.titleLarge)
                Text("Recovery role", fontWeight = FontWeight.SemiBold)
                Text(if (current.keyStatus.publicKey == null) "This device has no recovery-only encryption key." else "This device can receive a named recovery share.")
                Button(enabled = !busy && current.keyStatus.publicKey == null, onClick = { launchAction(onRegister) }) { Text("Enable this device as a recoverer") }

                Text("Your recovery policy", fontWeight = FontWeight.SemiBold)
                if (current.configuration.configured) {
                    Text("Two participants are required: your device, the named recoverer, or the host.")
                    Text("Recoverer: ${current.configuration.recoverer ?: "Unavailable"}")
                    Text("Policy version ${current.configuration.epoch ?: 0}")
                } else Text("Recovery has not been configured.")
                OutlinedTextField(
                    value = recoverer,
                    onValueChange = { recoverer = it.trim() },
                    enabled = !busy && privateNodeState == MemberPrivateNodeState.READY,
                    label = { Text("Recoverer household reference") },
                    modifier = Modifier.fillMaxWidth(),
                )
                Button(
                    enabled = !busy && canConfigure && privateNodeState == MemberPrivateNodeState.READY && recoverer.isNotEmpty() && recoverer != session.household,
                    onClick = { val selected = recoverer; launchAction { onConfigure(it, selected) } },
                ) { Text("Review and configure recovery") }
                if (!canConfigure) Text("This build has no independently delivered recovery notice channel, so recovery configuration remains closed.")

                if (privateNodeState == MemberPrivateNodeState.RECOVERY_REQUIRED) {
                    Text("Restore this device", fontWeight = FontWeight.SemiBold)
                    Text("A recovered passkey does not restore the encrypted records by itself.")
                    Button(enabled = !busy, onClick = { launchAction(onBegin) }) { Text("Begin lost-device recovery") }
                }

                Text("Ceremonies", fontWeight = FontWeight.SemiBold)
                if (current.requests.isEmpty()) Text("No recovery ceremony is visible to this account.")
                current.requests.forEach { request ->
                    Card(modifier = Modifier.fillMaxWidth()) {
                        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            Text(request.state.replaceFirstChar { it.uppercase() }, fontWeight = FontWeight.SemiBold)
                            Text(if (request.owner == session.household) "Your recovery" else "Recovery requested by a person who named you")
                            Text("Policy version ${request.epoch}")
                            if (request.recoverer == session.household && request.state == "pending") {
                                Button(enabled = !busy, onClick = { launchAction { onApprove(it, request) } }) { Text("Review and approve recovery") }
                            }
                            if (request.owner == session.household && request.state == "completed") {
                                Button(enabled = !busy && privateNodeState == MemberPrivateNodeState.RECOVERY_REQUIRED, onClick = { launchAction { onFinish(it, request) } }) { Text("Install recovered key") }
                            }
                            if (request.owner == session.household && request.state == "approved") Text("The recoverer approved. The key remains unavailable until the independent notice is delivered.")
                        }
                    }
                }

                Text("Recovery record", fontWeight = FontWeight.SemiBold)
                if (current.log.events.isEmpty()) Text("No completed or pending recovery event.")
                current.log.events.forEach { event -> Text(if (event.state == "completed") "Notice delivered before recovery completed" else "Recovery recorded; notice delivery pending") }
                TextButton(enabled = !busy, onClick = { refresh++ }) { Text("Refresh recovery status") }
                if (busy) Text("Working…")
                if (notice.isNotEmpty()) Text(notice)
            }
        }
    }
}

@Composable
private fun MemberSavedOperationsCard(
    session: MemberSessionInfo?,
    onLoad: suspend (MemberSessionInfo) -> List<MemberOperationHandle>,
    onCheck: suspend (MemberOperationHandle) -> MemberSavedResult,
    onPrepareWithdrawal: suspend (MemberSessionInfo, MemberOperationHandle) -> MemberWithdrawalReview,
    onApproveWithdrawal: suspend (MemberWithdrawalReview) -> MemberWithdrawalActionResult,
    onCancel: suspend (MemberOperationHandle) -> Unit,
) {
    var handles by remember(session) { mutableStateOf<List<MemberOperationHandle>?>(null) }
    var failure by remember(session) { mutableStateOf(false) }
    var checking by remember(session) { mutableStateOf<String?>(null) }
    var notices by remember(session) { mutableStateOf<Map<String, String>>(emptyMap()) }
    var withdrawal by remember(session) { mutableStateOf<MemberWithdrawalReview?>(null) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(session) {
        val current = session ?: return@LaunchedEffect
        try { handles = onLoad(current) } catch (failureValue: Exception) {
            if (failureValue is CancellationException) throw failureValue
            failure = true
        }
    }
    when {
        session == null -> MemberCard("Saved activity is locked", "Sign in before checking saved decisions or statements.")
        failure -> MemberCard("Saved activity is unavailable", "The private operation journal could not be opened.")
        handles == null -> MemberCard("Loading saved activity…", "Opening the encrypted operation journal.")
        handles!!.isEmpty() -> MemberCard("No saved activity", "Prepared and submitted decisions will appear here.")
        else -> Card(modifier = Modifier.fillMaxWidth()) {
            Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("Saved activity", style = MaterialTheme.typography.titleLarge)
                withdrawal?.let { review ->
                    Card(modifier = Modifier.fillMaxWidth()) {
                        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            Text("Withdraw recorded decision", fontWeight = FontWeight.SemiBold)
                            Text("Original total: ${review.frozen.total}. Cooling deadline: ${review.frozen.coolingEndsAt}.")
                            Text("Signing returns the proposal to a presented state. It does not reverse or confirm a payment.")
                            Button(enabled = checking == null, onClick = {
                                checking = review.handle.id; scope.launch {
                                    val message = try {
                                        when (val result = onApproveWithdrawal(review)) {
                                            is MemberWithdrawalActionResult.Outcome -> describeWithdrawal(result.value)
                                            MemberWithdrawalActionResult.Cancelled -> "Approval cancelled. Nothing was submitted."
                                            MemberWithdrawalActionResult.NoCredential -> "No passkey is available for this operation."
                                            is MemberWithdrawalActionResult.Failed -> "Approval could not be confirmed. Check the saved result before acting again."
                                        }
                                    } catch (failureValue: Exception) {
                                        if (failureValue is CancellationException) throw failureValue
                                        "Approval could not be confirmed. Check the saved result before acting again."
                                    }
                                    notices = notices + (review.handle.id to message); withdrawal = null
                                    handles = try { onLoad(session) } catch (_: Exception) { handles }
                                    checking = null
                                }
                            }) { Text(if (checking == review.handle.id) "Signing…" else "Sign withdrawal") }
                        }
                    }
                }
                handles!!.forEach { handle ->
                    val label = when (handle.operationProfile) {
                        MEMBER_DECISION_PROFILE -> "Digital decision"
                        MEMBER_STATEMENT_PROFILE -> "Box statement"
                        else -> "Decision withdrawal"
                    }
                    Card(modifier = Modifier.fillMaxWidth()) {
                        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            Text(label, fontWeight = FontWeight.SemiBold)
                            Text(if (handle.attempted) "Submission attempted" else "Prepared, not submitted")
                            Button(enabled = checking == null, onClick = {
                                checking = handle.id; scope.launch {
                                    notices = notices + (handle.id to try { describeSaved(onCheck(handle)) } catch (failureValue: Exception) {
                                        if (failureValue is CancellationException) throw failureValue
                                        "The result could not be read. Check later and do not resubmit."
                                    })
                                    checking = null
                                }
                            }) { Text(if (checking == handle.id) "Checking…" else "Check result") }
                            if (handle.operationProfile == MEMBER_DECISION_PROFILE && handle.attempted) {
                                Button(enabled = checking == null, onClick = {
                                    checking = handle.id; scope.launch {
                                        try {
                                            withdrawal = onPrepareWithdrawal(session, handle)
                                            notices = notices + (handle.id to "Review the recorded decision and cooling deadline before signing.")
                                            handles = onLoad(session)
                                        } catch (failureValue: Exception) {
                                            if (failureValue is CancellationException) throw failureValue
                                            notices = notices + (handle.id to "The withdrawal could not be prepared. Check the recorded decision and current proposal.")
                                        }
                                        checking = null
                                    }
                                }) { Text(if (checking == handle.id) "Preparing…" else "Prepare withdrawal") }
                            }
                            if (!handle.attempted) {
                                TextButton(enabled = checking == null, onClick = {
                                    checking = handle.id; scope.launch {
                                        notices = notices + (handle.id to try {
                                            onCancel(handle); "Prepared operation cancelled. No signed submission was sent."
                                        } catch (failureValue: Exception) {
                                            if (failureValue is CancellationException) throw failureValue
                                            "Cancellation could not be confirmed. Check the saved result."
                                        })
                                        checking = null
                                    }
                                }) { Text("Cancel prepared operation") }
                            }
                            notices[handle.id]?.let { Text(it) }
                        }
                    }
                }
            }
        }
    }
}

private fun describeSaved(result: MemberSavedResult): String = when (result) {
    is MemberSavedResult.Decision -> when (val value = result.value) {
        is MemberDecisionOutcome.Recorded -> "The original decision was recorded. This does not confirm payment or current order status."
        is MemberDecisionOutcome.Pending -> "No committed decision is reported. State: ${value.state}. Nothing was resubmitted."
        MemberDecisionOutcome.Unresolved -> "The result could not be read. Check later and do not resubmit."
    }
    is MemberSavedResult.Statement -> when (val value = result.value) {
        is MemberStatementOutcome.Committed -> "A matching protocol settlement was recorded for this device."
        is MemberStatementOutcome.SettledElsewhere -> "The box settled under another or unverified confirmation."
        is MemberStatementOutcome.Pending -> "No committed statement is reported. State: ${value.state}. Nothing was resubmitted."
        MemberStatementOutcome.Unresolved -> "The result could not be read. Check later and do not resubmit."
    }
    is MemberSavedResult.Withdrawal -> describeWithdrawal(result.value)
}

private fun describeWithdrawal(value: MemberWithdrawalOutcome): String = when (value) {
    is MemberWithdrawalOutcome.Recorded -> "The withdrawal was recorded. Refresh the proposal before choosing again. This does not confirm payment or current order status."
    is MemberWithdrawalOutcome.Pending -> "No committed withdrawal is reported. State: ${value.state}. Nothing was resubmitted."
    MemberWithdrawalOutcome.Unresolved -> "The result could not be read. Check later and do not resubmit."
}

@Composable
private fun MemberPermissionsCard(
    session: MemberSessionInfo?,
    onLoadPermissions: suspend () -> MemberPermissionList,
    onRevoke: suspend (MemberPermission) -> MemberPermission,
    onLoadRequests: suspend () -> List<MemberPermissionRequest>,
    onReadRequest: suspend (String) -> MemberPermissionRequest,
    onDecide: suspend (MemberPermissionRequest, Boolean) -> MemberPermissionRequest,
) {
    var permissions by remember(session) { mutableStateOf<List<MemberPermission>?>(null) }
    var requests by remember(session) { mutableStateOf<List<MemberPermissionRequest>?>(null) }
    var review by remember(session) { mutableStateOf<MemberPermissionRequest?>(null) }
    var busy by remember(session) { mutableStateOf(false) }
    var failed by remember(session) { mutableStateOf(false) }
    var notice by remember(session) { mutableStateOf("") }
    var refresh by remember(session) { mutableStateOf(0L) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(session, refresh) {
        if (session == null) return@LaunchedEffect
        failed = false
        try {
            permissions = onLoadPermissions().permissions
            requests = onLoadRequests()
        } catch (failureValue: Exception) {
            if (failureValue is CancellationException) throw failureValue
            failed = true
        }
    }
    when {
        session == null -> MemberCard("Access is locked", "Sign in before reviewing permissions or access requests.")
        failed -> MemberCard("Access could not be checked", "Refresh before relying on current permission status.")
        permissions == null || requests == null -> MemberCard("Checking access…", "Reading current permissions and requests.")
        else -> Card(modifier = Modifier.fillMaxWidth()) {
            Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("Access", style = MaterialTheme.typography.titleLarge)
                Text("Permissions", fontWeight = FontWeight.SemiBold)
                if (permissions!!.isEmpty()) Text("No permission history.")
                permissions!!.forEach { permission ->
                    val now = System.currentTimeMillis()
                    val status = if (permission.revokedAt != null) "Revoked" else if (permission.expiresAt <= now) "Expired" else "Active"
                    Card(modifier = Modifier.fillMaxWidth()) {
                        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Text(permission.purpose, fontWeight = FontWeight.SemiBold)
                            Text("Granted to ${permission.grantee} · ${permission.scope.joinToString()}")
                            Text(status)
                            if (status == "Active") Button(enabled = !busy, onClick = {
                                busy = true; scope.launch {
                                    notice = try { onRevoke(permission); "Permission revoked. Refreshing current access." }
                                    catch (failureValue: Exception) {
                                        if (failureValue is CancellationException) throw failureValue
                                        "Revocation could not be confirmed. Refresh before taking another action."
                                    }
                                    busy = false; refresh++
                                }
                            }) { Text("Revoke permission") }
                        }
                    }
                }
                Text("Requests", fontWeight = FontWeight.SemiBold)
                if (requests!!.isEmpty()) Text("No access requests.")
                requests!!.forEach { request ->
                    Card(modifier = Modifier.fillMaxWidth()) {
                        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Text(request.terms.requester.name, fontWeight = FontWeight.SemiBold)
                            Text(request.terms.action)
                            Text("State: ${request.state}")
                            if (request.canDecide(System.currentTimeMillis())) Button(enabled = !busy, onClick = {
                                busy = true; scope.launch {
                                    try { review = onReadRequest(request.id); notice = "Review the purpose, field, and access deadline before deciding." }
                                    catch (failureValue: Exception) {
                                        if (failureValue is CancellationException) throw failureValue
                                        notice = "This request could not be checked."
                                    }
                                    busy = false
                                }
                            }) { Text("Review request") }
                        }
                    }
                }
                review?.let { selected ->
                    Card(modifier = Modifier.fillMaxWidth()) {
                        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            Text("Permission request", fontWeight = FontWeight.SemiBold)
                            Text(selected.terms.requester.name)
                            Text(selected.terms.purpose)
                            Text(selected.terms.fields.joinToString { it.label })
                            Text("Access deadline: ${selected.terms.accessExpiresAt}")
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                listOf(true to "Grant", false to "Decline").forEach { (grant, label) ->
                                    Button(enabled = !busy && selected.canDecide(System.currentTimeMillis()), onClick = {
                                        busy = true; scope.launch {
                                            notice = try {
                                                val result = onDecide(selected, grant); review = result
                                                if (grant) "Permission decision recorded." else "Request cancelled. No permission was granted."
                                            } catch (failureValue: Exception) {
                                                if (failureValue is CancellationException) throw failureValue
                                                review = null; "The result could not be confirmed. Refresh before taking another action."
                                            }
                                            busy = false; refresh++
                                        }
                                    }) { Text(label) }
                                }
                            }
                        }
                    }
                }
                if (notice.isNotEmpty()) Text(notice)
                TextButton(enabled = !busy, onClick = { refresh++ }) { Text("Refresh access") }
            }
        }
    }
}

@Composable
private fun MemberDialsCard(
    session: MemberSessionInfo?,
    onLoadEffective: suspend () -> List<Mandate>,
    onLoadChanges: suspend () -> List<MemberMandateChange>,
    onPrepare: suspend (Mandate) -> PreparedMemberMandateChange,
    onPrepareSignature: suspend (String) -> PreparedMemberMandateChange,
    onApprove: suspend (PreparedMemberMandateChange) -> MemberDialsActionResult,
    onCancelChange: suspend (String) -> MemberMandateChange,
) {
    var effective by remember(session) { mutableStateOf<List<Mandate>?>(null) }
    var changes by remember(session) { mutableStateOf<List<MemberMandateChange>?>(null) }
    var editing by remember(session) { mutableStateOf<Mandate?>(null) }
    var prepared by remember(session) { mutableStateOf<PreparedMemberMandateChange?>(null) }
    var outOfNetwork by remember(session) { mutableStateOf("") }
    var daily by remember(session) { mutableStateOf("") }
    var cooling by remember(session) { mutableStateOf("") }
    var lapses by remember(session) { mutableStateOf("") }
    var coSigners by remember(session) { mutableStateOf("") }
    var busy by remember(session) { mutableStateOf(false) }
    var failed by remember(session) { mutableStateOf(false) }
    var notice by remember(session) { mutableStateOf("") }
    var refresh by remember(session) { mutableStateOf(0L) }
    val scope = rememberCoroutineScope()
    fun begin(value: Mandate) {
        editing = value; prepared = null; outOfNetwork = value.ceilingOutOfNetwork.toString(); daily = value.ceilingDaily?.toString().orEmpty()
        cooling = value.coolingSeconds?.toString().orEmpty(); lapses = value.lapsesAt.toString(); coSigners = value.coSigners.joinToString(",")
    }
    LaunchedEffect(session, refresh) {
        if (session == null) return@LaunchedEffect
        failed = false
        try { effective = onLoadEffective(); changes = onLoadChanges() }
        catch (failureValue: Exception) { if (failureValue is CancellationException) throw failureValue; failed = true }
    }
    when {
        session == null -> MemberCard("Dials are locked", "Sign in before reviewing or changing household protections.")
        failed -> MemberCard("Dials could not be refreshed", "The effective mandate has not been changed. Refresh before editing.")
        effective == null || changes == null -> MemberCard("Checking Dials…", "Reading effective protections and pending signatures.")
        else -> Card(modifier = Modifier.fillMaxWidth()) {
            Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("Dials", style = MaterialTheme.typography.titleLarge)
                if (effective!!.isEmpty()) Text("No effective mandate is available.")
                effective!!.forEach { mandate ->
                    Card(modifier = Modifier.fillMaxWidth()) {
                        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Text("Effective version ${mandate.version}", fontWeight = FontWeight.SemiBold)
                            Text(describeMandate(mandate))
                            Button(enabled = !busy, onClick = { begin(mandate) }) { Text("Edit protections") }
                        }
                    }
                }
                editing?.let { base ->
                    Card(modifier = Modifier.fillMaxWidth()) {
                        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text("Proposed version ${base.version + 1}", fontWeight = FontWeight.SemiBold)
                            OutlinedTextField(outOfNetwork, { outOfNetwork = it }, label = { Text("Out-of-network ceiling") }, singleLine = true)
                            OutlinedTextField(daily, { daily = it }, label = { Text("Daily ceiling (blank means none)") }, singleLine = true)
                            OutlinedTextField(cooling, { cooling = it }, label = { Text("Cooling seconds (blank means none)") }, singleLine = true)
                            OutlinedTextField(lapses, { lapses = it }, label = { Text("Lapses at") }, singleLine = true)
                            OutlinedTextField(coSigners, { coSigners = it }, label = { Text("Co-signers, comma separated") }, singleLine = true)
                            Button(enabled = !busy, onClick = {
                                val proposal = try {
                                    val signers = coSigners.split(',').map { it.trim() }.filter { it.isNotEmpty() }
                                    Mandate(base.id, base.household, checkNotNull(outOfNetwork.toLongOrNull()), daily.takeIf { it.isNotBlank() }?.toLong(),
                                        cooling.takeIf { it.isNotBlank() }?.toLong(), signers, checkNotNull(lapses.toLongOrNull()), base.version + 1).also {
                                        Canonical.validateMandate(it); require(signers.distinct().size == signers.size)
                                    }
                                } catch (_: Exception) { notice = "Enter valid safe integer limits and unique co-signers."; null }
                                if (proposal != null) {
                                    busy = true; scope.launch {
                                        try { prepared = onPrepare(proposal); notice = "Review every before/after protection and required signer before signing." }
                                        catch (failureValue: Exception) { if (failureValue is CancellationException) throw failureValue; notice = "The proposal could not be fixed. Refresh Dials before editing again." }
                                        busy = false
                                    }
                                }
                            }) { Text("Review fixed proposal") }
                        }
                    }
                }
                Text("Pending changes", fontWeight = FontWeight.SemiBold)
                if (changes!!.isEmpty()) Text("No pending or historical mandate changes.")
                changes!!.forEach { change ->
                    Card(modifier = Modifier.fillMaxWidth()) {
                        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Text("${change.state.replaceFirstChar { it.uppercase() }} · version ${change.mandate.version}", fontWeight = FontWeight.SemiBold)
                            Text("Before: ${describeMandate(change.before)}")
                            Text("After: ${describeMandate(change.mandate)}")
                            Text("Required: ${change.requiredSigners.joinToString()}")
                            Text("Signed: ${change.signedBy.joinToString().ifEmpty { "None" }}")
                            if (change.state == "pending" && session.household in change.requiredSigners && session.household !in change.signedBy) {
                                Button(enabled = !busy, onClick = { busy = true; scope.launch {
                                    try { prepared = onPrepareSignature(change.id); notice = "Review this fixed proposal before adding your signature." }
                                    catch (failureValue: Exception) { if (failureValue is CancellationException) throw failureValue; notice = "This pending proposal could not be checked." }
                                    busy = false
                                } }) { Text("Review signature") }
                            }
                            if (change.state == "pending") TextButton(enabled = !busy, onClick = { busy = true; scope.launch {
                                notice = try { onCancelChange(change.id); prepared = null; "Pending change cancelled. The effective version was not changed." }
                                catch (failureValue: Exception) { if (failureValue is CancellationException) throw failureValue; "Cancellation could not be confirmed. Refresh Dials." }
                                busy = false; refresh++
                            } }) { Text("Cancel pending change") }
                        }
                    }
                }
                prepared?.let { fixed ->
                    Card(modifier = Modifier.fillMaxWidth()) {
                        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            Text("Signature review", fontWeight = FontWeight.SemiBold)
                            Text("Before: ${describeMandate(fixed.change.before)}")
                            Text("After: ${describeMandate(fixed.change.mandate)}")
                            Text("Required signers: ${fixed.change.requiredSigners.joinToString()}")
                            Button(enabled = !busy, onClick = { busy = true; scope.launch {
                                notice = when (val result = onApprove(fixed)) {
                                    is MemberDialsActionResult.Recorded -> if (result.change.state == "effective") "Mandate version ${result.change.mandate.version} is effective." else "Signature recorded. Waiting for required signers."
                                    MemberDialsActionResult.Cancelled -> "Signing cancelled. The effective mandate was not changed."
                                    MemberDialsActionResult.NoCredential -> "No passkey is available for this mandate."
                                    is MemberDialsActionResult.Failed -> "The submission result is unconfirmed. Refresh Dials; do not sign a new version yet."
                                }
                                prepared = null; editing = null; busy = false; refresh++
                            } }) { Text("Sign fixed proposal") }
                            TextButton(enabled = !busy, onClick = { prepared = null }) { Text("Close review") }
                        }
                    }
                }
                if (notice.isNotEmpty()) Text(notice)
                TextButton(enabled = !busy, onClick = { prepared = null; editing = null; refresh++ }) { Text("Refresh Dials") }
            }
        }
    }
}

private fun describeMandate(value: Mandate) = "Out-of-network ${value.ceilingOutOfNetwork}; daily ${value.ceilingDaily?.toString() ?: "none"}; " +
    "cooling ${value.coolingSeconds?.toString() ?: "none"}; co-signers ${value.coSigners.joinToString().ifEmpty { "none" }}; lapses ${value.lapsesAt}"

private fun Exception.endsPrivateSession() = this is MemberFailure.Expired || this is MemberFailure.Superseded || (this is MemberFailure.Http && status == 401)

@Composable
private fun MemberAccountCard(
    onSignIn: suspend () -> MemberAuthenticationResult,
    onRegister: suspend (String) -> MemberAuthenticationResult,
    onSignedIn: suspend (MemberSessionInfo) -> MemberPrivateNodeState,
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
                    if (result is MemberAuthenticationResult.SignedIn) {
                        status = try {
                            when (onSignedIn(result.session)) {
                                MemberPrivateNodeState.READY -> "Connected. Encrypted private records are ready."
                                MemberPrivateNodeState.RECOVERY_REQUIRED -> "Connected, but this installation needs recovery before protected actions can open."
                                MemberPrivateNodeState.LOCKED -> "Connected, but private records could not be opened."
                            }
                        } catch (failureValue: Exception) {
                            if (failureValue is CancellationException) throw failureValue
                            "Connected, but private records are unavailable. Protected actions remain closed."
                        }
                    }
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

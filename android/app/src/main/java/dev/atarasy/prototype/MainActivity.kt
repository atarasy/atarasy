package dev.atarasy.prototype

import android.net.Uri
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.compose.foundation.clickable
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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.material3.Tab
import androidx.compose.material3.TabRow
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow
import java.io.File
import java.time.LocalDate

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
    private lateinit var leaveService: MemberLeaveService
    private lateinit var leaveFlow: MemberLeaveFlow

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
        leaveService = MemberLeaveService(environment, memberSessions, acceptedOrigins = AndroidSigningOrigins.current(this))
        leaveFlow = MemberLeaveFlow(leaveService, memberSessions, privateNode, passkeys, operationStore)
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
                onSetHostMoveSession = { hostMoveFlow?.setSession(it); leaveFlow.setSession(it) },
                onPrepareHostMove = { hostMoveFlow?.prepare() ?: MemberHostMoveState(MemberHostMovePhase.SOURCE_RETAINED, "No trusted target host is configured.") },
                onRetireSourceHost = { hostMoveFlow?.retireSource() ?: MemberHostMoveState(MemberHostMovePhase.UNRESOLVED, "Source retirement is unavailable.") },
                onRegisterRefresh = androidRefresh::register,
                refreshEvents = MemberAndroidRefreshEvents.events,
                onRefreshLeaveStatus = leaveFlow::refreshStatus,
                onDeleteAccount = leaveFlow::deleteAccount,
                onRequestAccountExport = leaveService::export,
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
    onRefreshLeaveStatus: suspend () -> MemberLeaveState = { MemberLeaveState() },
    onDeleteAccount: suspend () -> MemberLeaveState = { MemberLeaveState() },
    onRequestAccountExport: suspend () -> MemberExport = { throw MemberFailure.Unavailable },
) {
    var selectedSection by rememberSaveable { mutableStateOf("Inbox") }
    var accountSection by rememberSaveable { mutableStateOf("Home") }
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
                    if (session != null) {
                        // Three destinations (vault `80` §6.1): Inbox, Limits, Account. A result is
                        // reached from its offer or from Account, never from a fourth top-level list.
                        // Shown even while locked, since Account is where Recovery is reached.
                        val tabs = listOf("Inbox" to R.string.tab_inbox, "Limits" to R.string.tab_limits, "Account" to R.string.tab_account)
                        TabRow(selectedTabIndex = tabs.indexOfFirst { it.first == selectedSection }.coerceAtLeast(0)) {
                            tabs.forEach { (key, label) ->
                                Tab(selected = selectedSection == key, onClick = { selectedSection = key; accountSection = "Home" }, text = { Text(stringResource(label)) })
                            }
                        }
                    }
                    Spacer(Modifier.height(8.dp))
                    if (selectedSection == "Limits") {
                        MemberDialsCard(accessSession, onLoadEffectiveMandates, onLoadMandateChanges, onPrepareMandateChange, onPrepareMandateSignature, onApproveMandateChange, onCancelMandateChange)
                    } else if (selectedSection == "Account") {
                        when {
                            session == null -> MemberAccountCard(
                                onSignIn = onSignIn,
                                onRegister = onRegister,
                                onSignedIn = { info ->
                                    session = info; privateNodeState = onOpenPrivateNode(info)
                                    onSetHostMoveSession(info)
                                    refreshNotice = try {
                                        onRegisterRefresh(); "Private update notifications are enabled. Notifications contain no proposal details."
                                    } catch (_: Exception) { "Update notifications are unavailable. Foreground refresh remains available." }
                                    selectedSection = "Inbox"
                                    privateNodeState
                                },
                            )
                            accountSection == "Saved" -> MemberAccountSubScreen(title = stringResource(R.string.account_my_records), onBack = { accountSection = "Home" }) {
                                MemberSavedOperationsCard(accessSession, onLoadSaved, onCheckSaved, onPrepareWithdrawal, onApproveWithdrawal, onCancelOperation)
                            }
                            accountSection == "Access" -> MemberAccountSubScreen(title = stringResource(R.string.account_sharing), onBack = { accountSection = "Home" }) {
                                MemberPermissionsCard(accessSession, onLoadPermissions, onRevokePermission, onLoadPermissionRequests, onReadPermissionRequest, onDecidePermissionRequest)
                            }
                            accountSection == "Recovery" -> MemberAccountSubScreen(title = stringResource(R.string.account_recovery), onBack = { accountSection = "Home" }) {
                                MemberRecoveryCard(
                                    session, privateNodeState, recoveryCanConfigure, onLoadRecovery, onRegisterRecoveryKey, onConfigureRecovery,
                                    onBeginRecovery, onApproveRecovery,
                                    onFinish = { info, request -> onFinishRecovery(info, request).also { if (it is MemberRecoveryActionResult.Completed) privateNodeState = MemberPrivateNodeState.READY } },
                                )
                            }
                            accountSection == "MoveHost" -> MemberAccountSubScreen(title = stringResource(R.string.account_move_host), onBack = { accountSection = "Home" }) {
                                MemberHostMoveCard(
                                    accessSession, onPrepareHostMove,
                                    onRetire = {
                                        onRetireSourceHost().also {
                                            if (it.phase == MemberHostMovePhase.COMPLETED) {
                                                session = null; privateNodeState = MemberPrivateNodeState.LOCKED; onSetHostMoveSession(null); accountSection = "Home"
                                            }
                                        }
                                    },
                                )
                            }
                            accountSection == "Delete" -> MemberAccountSubScreen(title = stringResource(R.string.account_delete_account), onBack = { accountSection = "Home" }) {
                                MemberLeaveCard(
                                    accessSession,
                                    onRefreshStatus = onRefreshLeaveStatus,
                                    onDeleteAccount = {
                                        onDeleteAccount().also {
                                            if (it.phase == MemberLeavePhase.DONE) {
                                                session = null; privateNodeState = MemberPrivateNodeState.LOCKED; onSetHostMoveSession(null); accountSection = "Home"
                                            }
                                        }
                                    },
                                    onRequestExport = onRequestAccountExport,
                                )
                            }
                            else -> MemberAccountHomeCard(
                                session = session,
                                notice = refreshNotice,
                                onOpenSaved = { accountSection = "Saved" },
                                onOpenAccess = { accountSection = "Access" },
                                onOpenRecovery = { accountSection = "Recovery" },
                                onOpenMoveHost = if (hostMoveAvailable) ({ accountSection = "MoveHost" }) else null,
                                onOpenDelete = { accountSection = "Delete" },
                                onSignOut = {
                                    session = null; privateNodeState = MemberPrivateNodeState.LOCKED; onSetHostMoveSession(null); selectedSection = "Account"; accountSection = "Home"
                                },
                            )
                        }
                    } else {
                        MemberInboxCard(
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

private fun describeLeaveBlocker(blocker: MemberLeaveBlocker) = when (blocker.kind) {
    "offer_in_progress" -> "An offer is still being decided."
    "statement_unsigned" -> "A statement is waiting for your signature."
    "reservation_held" -> "A reservation is still held."
    "gift_in_flight" -> "A gift you sent or received is still in transit."
    "co_signer" -> "You are a required co-signer on another household's mandate."
    "recoverer" -> "You are set as another household's recovery contact."
    "host_move_pending" -> "A move to another host is in progress."
    "operation_pending" -> "An operation is still awaiting its outcome."
    "mandate_change_pending" -> "A change to your protections is still pending."
    "recovery_request_pending" -> "A recovery request is still pending."
    else -> "Something with an unrecognised kind (\"${blocker.kind}\") is still in progress."
}

/** §14.3. Shows what would block deletion, offers to save a copy of the member's records
 * first, and only then asks for a passkey to confirm. `session` gates on the same
 * `accessSession` (signed in and the encrypted private node open) the other protected
 * sections use. */
@Composable
private fun MemberLeaveCard(
    session: MemberSessionInfo?,
    onRefreshStatus: suspend () -> MemberLeaveState,
    onDeleteAccount: suspend () -> MemberLeaveState,
    onRequestExport: suspend () -> MemberExport,
) {
    var state by remember(session) { mutableStateOf(MemberLeaveState()) }
    var busy by remember(session) { mutableStateOf(false) }
    var confirming by remember(session) { mutableStateOf(false) }
    var exportBusy by remember(session) { mutableStateOf(false) }
    var exportNotice by remember(session) { mutableStateOf("") }
    var pendingExport by remember(session) { mutableStateOf<MemberExport?>(null) }
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val saveExport = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/json")) { uri ->
        val export = pendingExport
        if (uri != null && export != null) {
            scope.launch {
                exportNotice = try {
                    context.contentResolver.openOutputStream(uri)?.use { it.write(export.fileContents()) } ?: throw MemberFailure.Storage
                    "Export saved."
                } catch (failure: Exception) {
                    if (failure is CancellationException) throw failure
                    "The export could not be saved to that location."
                }
            }
        }
    }
    LaunchedEffect(session) {
        state = if (session == null) MemberLeaveState() else onRefreshStatus()
    }
    when {
        session == null -> MemberCard("Delete account is locked", "Sign in and open the encrypted private records before deleting your account.")
        else -> Card(modifier = Modifier.fillMaxWidth()) {
            Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("Delete account", style = MaterialTheme.typography.titleLarge)
                Text(
                    "Deleting removes everything this host holds for your account: your offers, your permissions, your protections and your encrypted private records. " +
                        "Shops keep their own records of what you bought. Gifts you gave stay in the other household's records, showing you as a member who has left.",
                )
                Button(enabled = !exportBusy, onClick = {
                    exportBusy = true
                    scope.launch {
                        exportNotice = try {
                            pendingExport = onRequestExport(); "Choose where to save the export."
                        } catch (failure: Exception) {
                            if (failure is CancellationException) throw failure
                            "The export could not be prepared."
                        }
                        exportBusy = false
                        if (pendingExport != null) saveExport.launch("atarasy-export-${LocalDate.now()}.json")
                    }
                }) { Text(if (exportBusy) "Preparing export…" else "Save a copy of my records") }
                if (exportNotice.isNotEmpty()) Text(exportNotice)
                when (state.phase) {
                    MemberLeavePhase.IDLE, MemberLeavePhase.CHECKING_STATUS -> Text("Checking whether anything would block deletion…")
                    MemberLeavePhase.BLOCKED -> Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text("This is still in progress, so the account cannot be deleted yet:", fontWeight = FontWeight.SemiBold)
                        state.blockers.forEach { blocker -> Text("• " + describeLeaveBlocker(blocker)) }
                        TextButton(enabled = !busy, onClick = { busy = true; scope.launch { state = onRefreshStatus(); busy = false } }) { Text("Check again") }
                    }
                    MemberLeavePhase.READY -> if (!confirming) {
                        Button(enabled = !busy, onClick = { confirming = true }) { Text("Delete account") }
                    } else {
                        Text("This cannot be undone. Confirm with your passkey to permanently delete your account.", fontWeight = FontWeight.SemiBold)
                        Button(enabled = !busy, onClick = {
                            busy = true
                            scope.launch { state = onDeleteAccount(); confirming = false; busy = false }
                        }) { Text(if (busy) "Deleting…" else "Confirm deletion") }
                        TextButton(enabled = !busy, onClick = { confirming = false }) { Text("Cancel") }
                    }
                    MemberLeavePhase.SIGNING -> Text("Confirming with your passkey…")
                    MemberLeavePhase.DONE -> Text("Deleted. This device is now signed out.")
                    MemberLeavePhase.FAILED -> TextButton(enabled = !busy, onClick = { busy = true; scope.launch { state = onRefreshStatus(); busy = false } }) { Text("Check account status") }
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
    // Read once per composition: never call stringResource() from inside a launched coroutine.
    val recordedText = stringResource(R.string.notice_decision_recorded)
    val cancelledText = stringResource(R.string.notice_signing_cancelled)
    val noCredentialText = stringResource(R.string.notice_no_credential)
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
                Text(stringResource(R.string.limits_intro), style = MaterialTheme.typography.bodyMedium, color = Color.Gray)
                if (effective!!.isEmpty()) Text(stringResource(R.string.limits_no_limits))
                effective!!.forEach { mandate ->
                    Card(modifier = Modifier.fillMaxWidth()) {
                        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Text(stringResource(R.string.limits_your_limits), fontWeight = FontWeight.SemiBold)
                            Text(describeMandate(mandate))
                            Button(enabled = !busy, onClick = { begin(mandate) }) { Text(stringResource(R.string.limits_edit_button)) }
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
                            }) { Text(stringResource(R.string.limits_review_proposal)) }
                        }
                    }
                }
                Text(stringResource(R.string.limits_pending_changes_title), fontWeight = FontWeight.SemiBold)
                if (changes!!.isEmpty()) Text(stringResource(R.string.limits_no_pending))
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
                            Text(stringResource(R.string.limits_signature_review), fontWeight = FontWeight.SemiBold)
                            Text("Before: ${describeMandate(fixed.change.before)}")
                            Text("After: ${describeMandate(fixed.change.mandate)}")
                            Text("Required signers: ${fixed.change.requiredSigners.joinToString()}")
                            Button(enabled = !busy, onClick = { busy = true; scope.launch {
                                notice = when (val result = onApprove(fixed)) {
                                    is MemberDialsActionResult.Recorded -> if (result.change.state == "effective") recordedText else "Signature recorded. Waiting for required signers."
                                    MemberDialsActionResult.Cancelled -> cancelledText
                                    MemberDialsActionResult.NoCredential -> noCredentialText
                                    is MemberDialsActionResult.Failed -> "The submission result is unconfirmed. Refresh before signing a new version."
                                }
                                prepared = null; editing = null; busy = false; refresh++
                            } }) { Text(stringResource(R.string.limits_sign_proposal)) }
                            TextButton(enabled = !busy, onClick = { prepared = null }) { Text("← " + stringResource(R.string.tab_limits)) }
                        }
                    }
                }
                if (notice.isNotEmpty()) Text(notice)
                TextButton(enabled = !busy, onClick = { prepared = null; editing = null; refresh++ }) { Text(stringResource(R.string.inbox_refresh)) }
            }
        }
    }
}

/**
 * The five protections as sentences (vault `80` §6.2 L), not a raw field dump. Mirrors
 * iOS's `MemberMandateSentences`: hours and days, not seconds, and money in the host
 * currency.
 */
@Composable
private fun describeMandate(value: Mandate): String {
    val daily = value.ceilingDaily?.let { stringResource(R.string.limits_daily_sentence, MemberFormat.money(it)) } ?: ""
    val outOfNetwork = stringResource(R.string.limits_out_of_network_sentence, MemberFormat.money(value.ceilingOutOfNetwork))
    val cooling = value.coolingSeconds?.let { stringResource(R.string.limits_cooling_sentence, MemberFormat.duration(it)) } ?: stringResource(R.string.limits_no_cooling)
    val coSigners = if (value.coSigners.isEmpty()) stringResource(R.string.limits_no_cosigners) else stringResource(R.string.limits_cosigners_sentence, value.coSigners.size)
    val ends = stringResource(R.string.limits_ends_sentence, MemberFormat.day(value.lapsesAt))
    return listOfNotNull(daily.takeIf { it.isNotEmpty() }, outOfNetwork, cooling, coSigners, ends).joinToString("\n")
}

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
            }) { Text(if (busy) "Connecting…" else stringResource(R.string.account_sign_in_with_passkey)) }
            OutlinedTextField(
                value = invitation,
                onValueChange = { invitation = it.trim() },
                enabled = !busy,
                label = { Text(stringResource(R.string.account_device_invitation)) },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                modifier = Modifier.fillMaxWidth(),
            )
            Button(enabled = !busy && Regex("^aen1_[A-Za-z0-9_-]{43}$").matches(invitation), onClick = {
                val submitted = invitation; invitation = ""; busy = true
                scope.launch { status = describe(onRegister(submitted)); busy = false }
            }) { Text(stringResource(R.string.account_connect_device)) }
        }
    }
}

/** A destination reached from Account, with a way back to it (vault `80` §6.2 A). */
@Composable
private fun MemberAccountSubScreen(title: String, onBack: () -> Unit, content: @Composable () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = onBack) { Text("← " + stringResource(R.string.tab_account)) }
        }
        Text(title, style = MaterialTheme.typography.titleLarge)
        content()
    }
}

/**
 * Me, my devices, my data (vault `80` §6.2 A). The household's own reference moves to
 * "About this account" and is never the first line the member reads.
 */
@Composable
private fun MemberAccountHomeCard(
    session: MemberSessionInfo?,
    notice: String,
    onOpenSaved: () -> Unit,
    onOpenAccess: () -> Unit,
    onOpenRecovery: () -> Unit,
    onOpenMoveHost: (() -> Unit)?,
    onOpenDelete: () -> Unit,
    onSignOut: () -> Unit,
) {
    var showingAbout by rememberSaveable { mutableStateOf(false) }
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (session != null) MemberCard(stringResource(R.string.account_signed_in_with_passkey), stringResource(R.string.account_signed_in_until, MemberFormat.dayAndTime(session.expiresAt)))
        Card(modifier = Modifier.fillMaxWidth()) {
            Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                TextButton(onClick = onOpenSaved) { Text(stringResource(R.string.account_my_records)) }
            }
        }
        Card(modifier = Modifier.fillMaxWidth()) {
            Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(stringResource(R.string.account_sharing), style = MaterialTheme.typography.titleMedium)
                TextButton(onClick = onOpenAccess) { Text(stringResource(R.string.account_access_requests) + " / " + stringResource(R.string.account_shared)) }
            }
        }
        Card(modifier = Modifier.fillMaxWidth()) {
            Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(stringResource(R.string.account_your_data), style = MaterialTheme.typography.titleMedium)
                TextButton(onClick = onOpenRecovery) { Text(stringResource(R.string.account_recovery)) }
                if (onOpenMoveHost != null) TextButton(onClick = onOpenMoveHost) { Text(stringResource(R.string.account_move_host)) }
            }
        }
        if (notice.isNotEmpty()) MemberCard("Notifications", notice)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            TextButton(onClick = onSignOut) { Text(stringResource(R.string.account_sign_out)) }
            TextButton(onClick = onOpenDelete) { Text(stringResource(R.string.account_delete_account)) }
        }
        if (session != null) {
            Card(modifier = Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    TextButton(onClick = { showingAbout = !showingAbout }) { Text(stringResource(R.string.account_about_this_account)) }
                    if (showingAbout) {
                        Text(stringResource(R.string.account_reference_label), style = MaterialTheme.typography.bodySmall, color = Color.Gray)
                        Text(session.household, style = MaterialTheme.typography.bodySmall)
                    }
                }
            }
        }
    }
}

/**
 * Two sections, "At home" (physical) and "Proposals" (digital), each newest arrival first
 * over all presenters (`04b` §1b.2, clause 14, vault `80` §6.2 I). A row shows its goods'
 * title, its merchants, and one status line in the member's words: never a raw protocol
 * state word, never a raw offer id.
 */
@Composable
private fun MemberInboxCard(
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
        offers == null -> MemberCard(stringResource(R.string.inbox_loading), "")
        selectedOffer != null -> MemberOfferDetailCard(detail, detailFailed, review, reviewFailed, session, onPrepareDecision, onApproveDecision, onPrepareStatement, onApproveStatement, onRecorded) { onSelect(null) }
        else -> Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
            MemberInboxSection(
                title = stringResource(R.string.inbox_section_at_home_title),
                subtitle = stringResource(R.string.inbox_section_at_home_subtitle),
                rows = offers.inboxRows("physical"),
                empty = stringResource(R.string.inbox_empty_at_home),
                onSelect = onSelect,
            )
            MemberInboxSection(
                title = stringResource(R.string.inbox_section_proposals_title),
                subtitle = stringResource(R.string.inbox_section_proposals_subtitle),
                rows = offers.inboxRows("digital"),
                empty = stringResource(R.string.inbox_empty_proposals),
                onSelect = onSelect,
            )
            if (offers.isEmpty()) MemberCard(stringResource(R.string.inbox_no_sources), "")
        }
    }
}

@Composable
private fun MemberInboxSection(title: String, subtitle: String, rows: List<MemberOfferSummary>, empty: String, onSelect: (MemberOfferSummary) -> Unit) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(title, style = MaterialTheme.typography.titleLarge)
                Text(subtitle, style = MaterialTheme.typography.bodySmall, color = Color.Gray)
            }
            if (rows.isEmpty()) Text(empty, color = Color.Gray)
            rows.forEach { offer -> MemberInboxRow(offer = offer, onClick = { onSelect(offer) }) }
        }
    }
}

@Composable
private fun MemberInboxRow(offer: MemberOfferSummary, onClick: () -> Unit) {
    val lines = offer.candidates.orEmpty()
    val headline = when {
        lines.isEmpty() -> stringResource(if (offer.binding == "physical") R.string.inbox_row_box_generic else R.string.inbox_row_proposal_generic)
        lines.size == 1 -> lines.first().title
        else -> stringResource(R.string.inbox_row_and_more, lines.first().title, lines.size - 1)
    }
    Card(modifier = Modifier.fillMaxWidth(), onClick = onClick) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(headline, fontWeight = FontWeight.SemiBold)
            if (offer.merchants.isNotEmpty()) Text(offer.merchants.joinToString(", "), style = MaterialTheme.typography.bodySmall, color = Color.Gray)
            Text(memberRowStatusText(offer.rowStatus))
        }
    }
}

@Composable
private fun memberRowStatusText(status: MemberRowStatus): String = when (status) {
    is MemberRowStatus.AtHome -> status.nextSwap?.let { stringResource(R.string.status_next_swap, MemberFormat.day(it)) } ?: stringResource(R.string.status_at_home)
    is MemberRowStatus.StatementReady -> stringResource(if (status.holdsNextBox) R.string.status_statement_ready_holds_next else R.string.status_statement_ready)
    is MemberRowStatus.BoxClosed -> stringResource(if (status.settled) R.string.status_box_closed_settled else R.string.status_box_closed_not_settled)
    is MemberRowStatus.ProposalOpen -> status.closesAt?.let { stringResource(R.string.status_proposal_closes, MemberFormat.day(it)) } ?: stringResource(R.string.status_proposal_waiting)
    MemberRowStatus.ProposalDecided -> stringResource(R.string.status_proposal_decided)
    MemberRowStatus.ProposalClosed -> stringResource(R.string.status_proposal_closed)
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
            TextButton(onClick = onBack) { Text("← " + stringResource(R.string.tab_inbox)) }
            when {
                failed -> { Text("Offer unavailable", style = MaterialTheme.typography.titleLarge); Text("This offer could not be loaded.") }
                detail == null -> { Text("Loading offer…", style = MaterialTheme.typography.titleLarge) }
                else -> {
                    Text(
                        stringResource(if (detail.binding == "digital") R.string.inbox_row_proposal_generic else R.string.inbox_row_box_generic),
                        style = MaterialTheme.typography.titleLarge,
                    )
                    detail.candidates.forEach { candidate ->
                        Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                            Text(candidate.title, fontWeight = FontWeight.SemiBold)
                            Text("${candidate.quantity} × " + MemberFormat.money(candidate.unitPrice))
                            Text(stringResource(R.string.label_sold_by, candidate.merchant), style = MaterialTheme.typography.bodySmall, color = Color.Gray)
                            Text(stringResource(R.string.label_made_by, candidate.maker), style = MaterialTheme.typography.bodySmall, color = Color.Gray)
                            candidate.givenBy?.let { Text(stringResource(R.string.label_gift_from, it), style = MaterialTheme.typography.bodySmall, color = Color.Gray) }
                        }
                    }
                    detail.disclosures.forEach { block ->
                        block.items.forEach { item ->
                            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                Text(item.label, fontWeight = FontWeight.SemiBold)
                                Text(item.value)
                            }
                        }
                        // Question 72. Beside this block's own terms, and only where
                        // this merchant signed one. Tapping is the household's own
                        // act; nothing here sends anything on its behalf.
                        block.contact?.let { ContactLink(it) }
                    }
                    when {
                        reviewFailed -> Text("The decision review is unavailable.")
                        review == null -> Text("Loading decision review…")
                        review is MemberReview.Approval -> {
                            Text(stringResource(R.string.why_this_and_why_not), style = MaterialTheme.typography.titleMedium)
                            review.value.candidates.forEach { candidate ->
                                Text(candidate.argumentAgainst)
                                candidate.alternatives.forEach { Text("• $it") }
                                if (candidate.isExploration) Text(stringResource(R.string.label_new_to_you), style = MaterialTheme.typography.labelSmall, color = Color.Gray)
                            }
                            Text(review.value.carriage?.let { stringResource(R.string.label_delivery) + ": " + MemberFormat.money(it) } ?: stringResource(R.string.label_delivery_unknown))
                            if (session != null && detail.state == "presented") MemberDigitalDecisionControls(session, detail, review.value, onPrepareDecision, onApproveDecision, onRecorded)
                        }
                        review is MemberReview.Statement -> {
                            Text(stringResource(R.string.statement_title), style = MaterialTheme.typography.titleMedium)
                            review.value.lines.forEach { line ->
                                Text(line.title + ": " + (if (line.givenBy != null) stringResource(R.string.label_gift_from, line.givenBy) else MemberFormat.money(line.amount)))
                            }
                            Text(review.value.carriage?.let { stringResource(R.string.label_delivery) + ": " + MemberFormat.money(it) } ?: stringResource(R.string.label_delivery_unknown))
                            if (session != null && detail.state in setOf("decided", "expired")) MemberStatementControls(session, detail, review.value, onPrepareStatement, onApproveStatement, onRecorded)
                        }
                        review is MemberReview.Settlement -> {
                            Text(stringResource(R.string.settled_title), style = MaterialTheme.typography.titleMedium)
                            Text(stringResource(R.string.label_total) + ": " + MemberFormat.money(review.value.charged))
                            if (review.value.disputedAmount > 0) Text(stringResource(R.string.action_disputed) + ": " + MemberFormat.money(review.value.disputedAmount))
                            Text("This settlement is signed and is never rewritten.")
                            // §6.6, question 70. A correction only ever lowers what was
                            // signed, appended beside it. Nothing here is the household's
                            // to sign or dispute (clause 54): no refund request, no
                            // dispute control, no messaging.
                            review.corrections?.corrections?.takeIf { it.isNotEmpty() }?.let { rows ->
                                Text("Corrections", style = MaterialTheme.typography.titleMedium)
                                Text("The merchant of record has appended these to the settlement above.")
                                rows.forEach { correction ->
                                    Text("${if (correction.kind == "refund") "Refund" else "Collection"} from ${correction.merchant}: -${correction.amount}")
                                    // The merchant's own words, as plain text and never as markup.
                                    Text(correction.note)
                                }
                                Text("Net after corrections: ${review.corrections.net}")
                            }
                            // SPEC §6.6a. A refund the issuer returned, or the shop's own
                            // repayment. This platform moved no money either time and
                            // moves none now: the shop reaches the household by its own
                            // signed contact, or, where it signed none, by the return
                            // terms already beside its disclosure. Nothing here is sent
                            // to the merchant, and there is no refund action (clause 54).
                            review.corrections?.returns?.takeIf { it.isNotEmpty() }?.let { rows ->
                                Text("Returns", style = MaterialTheme.typography.titleMedium)
                                rows.forEach { ret ->
                                    if (ret.state == "returned") {
                                        Text("The refund from ${ret.merchant} did not reach you. The shop still owes it to you, off this platform.")
                                    } else {
                                        Text("${ret.merchant} reports it repaid this another way.")
                                    }
                                    Text(ret.note)
                                    MerchantContactOrTerms(review.disclosures, ret.merchant)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/**
 * Question 72. The plain link a tap opens: `mailto:`, `tel:` or the url itself. The
 * displayed text is the value verbatim, exactly as the merchant signed it. Nothing
 * here composes a message or sends anything on the household's behalf; the tap, if
 * there is one, is the household's own.
 */
@Composable
private fun ContactLink(contact: MemberDisclosureContact) {
    val uriHandler = LocalUriHandler.current
    Text(
        contact.value,
        color = MaterialTheme.colorScheme.primary,
        textDecoration = TextDecoration.Underline,
        modifier = Modifier.clickable { contactHref(contact)?.let(uriHandler::openUri) },
    )
}

private fun contactHref(contact: MemberDisclosureContact): String? = when (contact.kind) {
    "email" -> "mailto:" + Uri.encode(contact.value, "@.+-_")
    "tel" -> "tel:" + Uri.encode(contact.value, "+-")
    // Only https is a link, for the reason the iOS view gives.
    "url" -> contact.value.takeIf { Uri.parse(it).scheme.equals("https", ignoreCase = true) }
    else -> null
}

/**
 * SPEC §6.6a. A correction_return has no product, so the merchant's standing
 * disclosure (its `product`-less block) is what "its return terms" names. Where
 * the merchant signed a contact there, that is shown; where it signed none, the
 * block's own items stand in its place. Nothing is shown for a merchant with no
 * standing block at all: this hub never invents terms.
 */
@Composable
private fun MerchantContactOrTerms(blocks: List<MemberDisclosure>, merchant: String) {
    val block = blocks.firstOrNull { it.merchant == merchant && it.product == null } ?: return
    val contact = block.contact
    if (contact != null) {
        ContactLink(contact)
    } else {
        block.items.forEach { item ->
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(item.label, fontWeight = FontWeight.SemiBold)
                Text(item.value)
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
    // Read once per composition: never call stringResource() from inside a launched coroutine.
    val disputeText = stringResource(R.string.action_dispute)
    val disputedText = stringResource(R.string.action_disputed)
    val deliveryText = stringResource(R.string.label_delivery)
    val notPreparedText = "The statement could not be prepared. Refresh the offer before trying again."
    val recordedText = stringResource(R.string.notice_statement_recorded)
    val cancelledText = stringResource(R.string.notice_signing_cancelled)
    val noCredentialText = stringResource(R.string.notice_no_credential)
    val unresolvedText = stringResource(R.string.notice_unresolved)
    val checkRecordsText = "Check your records before another action."
    statement.lines.filter { it.valence in setOf("consumed", "lost") }.forEach { line ->
        TextButton(enabled = !busy && frozen == null, onClick = { disputed = if (line.candidate in disputed) disputed - line.candidate else disputed + line.candidate }) {
            Text((if (line.candidate in disputed) disputedText else disputeText) + ": " + line.title)
        }
    }
    if (frozen == null) {
        Button(enabled = !busy && statement.carriage != null, onClick = {
            busy = true; notice = ""; scope.launch {
                try { frozen = onPrepare(session, detail, statement, disputed.sorted()); notice = "" }
                catch (_: Exception) { notice = notPreparedText }
                busy = false
            }
        }) { Text(if (busy) stringResource(R.string.label_preparing) else stringResource(R.string.action_review_statement)) }
    } else {
        val value = frozen!!
        Text(
            MemberFormat.money(value.local.goodsCharged) +
                (if (value.local.disputedGoods > 0) " · $disputedText " + MemberFormat.money(value.local.disputedGoods) else "") +
                " · $deliveryText " + MemberFormat.money(value.local.carriage),
            fontWeight = FontWeight.SemiBold,
        )
        Button(enabled = !busy, onClick = {
            busy = true; notice = ""; scope.launch {
                when (val result = onApprove(value)) {
                    is MemberStatementActionResult.Outcome -> when (result.value) {
                        is MemberStatementOutcome.Committed -> { notice = recordedText; onRecorded() }
                        is MemberStatementOutcome.SettledElsewhere -> { frozen = null; notice = "This box was settled by another confirmation. Check your records." }
                        is MemberStatementOutcome.Pending -> { frozen = null; notice = checkRecordsText }
                        MemberStatementOutcome.Unresolved -> { frozen = null; notice = unresolvedText }
                    }
                    MemberStatementActionResult.Cancelled -> notice = cancelledText
                    MemberStatementActionResult.NoCredential -> notice = noCredentialText
                    is MemberStatementActionResult.Failed -> { frozen = null; notice = checkRecordsText }
                }
                busy = false
            }
        }) { Text(if (busy) stringResource(R.string.label_signing) else stringResource(R.string.action_sign_statement)) }
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
    // Read once per composition: never call stringResource() from inside a launched coroutine.
    val keepText = stringResource(R.string.action_keep)
    val declineText = stringResource(R.string.action_decline)
    val keepingText = stringResource(R.string.action_keeping)
    val decliningText = stringResource(R.string.action_declining)
    val totalText = stringResource(R.string.label_total)
    val deliveryText = stringResource(R.string.label_delivery)
    val notPreparedText = "The decision could not be prepared. Refresh the offer before trying again."
    val recordedText = stringResource(R.string.notice_decision_recorded)
    val cancelledText = stringResource(R.string.notice_signing_cancelled)
    val noCredentialText = stringResource(R.string.notice_no_credential)
    val unresolvedText = stringResource(R.string.notice_unresolved)
    val checkRecordsText = "Check your records before another action."
    approval.candidates.forEach { candidate ->
        Text(candidate.title, fontWeight = FontWeight.SemiBold)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(enabled = !busy && frozen == null, onClick = { choices = choices + (candidate.id to MemberDigitalChoice.KEEP) }) { Text(if (choices[candidate.id] == MemberDigitalChoice.KEEP) keepingText else keepText) }
            Button(enabled = !busy && frozen == null, onClick = { choices = choices + (candidate.id to MemberDigitalChoice.DECLINE) }) { Text(if (choices[candidate.id] == MemberDigitalChoice.DECLINE) decliningText else declineText) }
        }
    }
    val complete = approval.candidates.isNotEmpty() && approval.candidates.all { choices[it.id] in setOf(MemberDigitalChoice.KEEP, MemberDigitalChoice.DECLINE) }
    if (frozen == null) {
        Button(enabled = !busy && complete && approval.carriage != null, onClick = {
            busy = true; notice = ""
            scope.launch {
                try { frozen = onPrepare(session, detail, approval, choices); notice = "" }
                catch (_: Exception) { notice = notPreparedText }
                busy = false
            }
        }) { Text(if (busy) stringResource(R.string.label_preparing) else stringResource(R.string.action_review)) }
    } else {
        val value = frozen!!
        Text(
            MemberFormat.money(value.frozen.goods) + " · $deliveryText " + MemberFormat.money(value.frozen.carriage) + " · $totalText " + MemberFormat.money(value.frozen.total),
            fontWeight = FontWeight.SemiBold,
        )
        Button(enabled = !busy, onClick = {
            busy = true; notice = ""
            scope.launch {
                when (val result = onApprove(value)) {
                    is MemberDecisionActionResult.Outcome -> when (result.value) {
                        is MemberDecisionOutcome.Recorded -> { notice = recordedText; onRecorded() }
                        is MemberDecisionOutcome.Pending -> { frozen = null; notice = checkRecordsText }
                        MemberDecisionOutcome.Unresolved -> { frozen = null; notice = unresolvedText }
                    }
                    MemberDecisionActionResult.Cancelled -> notice = cancelledText
                    MemberDecisionActionResult.NoCredential -> notice = noCredentialText
                    is MemberDecisionActionResult.Failed -> { frozen = null; notice = checkRecordsText }
                }
                busy = false
            }
        }) { Text(if (busy) stringResource(R.string.label_signing) else stringResource(R.string.action_sign_with_passkey)) }
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

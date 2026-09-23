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
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberDatePickerState
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

/** Which message the locked screen shows beside `privateNodeState`, and whether a retry makes
 * sense. Mirrors iOS `MemberAccount.privateNodeNotice` / `privateNodeKeyMismatch` (#41): a read
 * that merely failed offers "Try again"; a key mismatch and recovery-required do not, since
 * retrying a read cannot fix either. */
private enum class PrivateNodeNotice { NONE, RECOVERY_REQUIRED, KEY_MISMATCH, TRANSIENT_FAILURE }

@Composable
fun AtarasyApp(
    onSignIn: suspend () -> MemberAuthenticationResult = { MemberAuthenticationResult.Failed(MemberFailure.Unavailable) },
    onRegister: suspend (String) -> MemberAuthenticationResult = { MemberAuthenticationResult.Failed(MemberFailure.Unavailable) },
    onLoadOffers: suspend (MemberSessionInfo) -> MemberOfferListResult = { throw MemberFailure.Unavailable },
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
    var sourcesIncomplete by remember { mutableStateOf(false) }
    var selectedOffer by remember { mutableStateOf<MemberOfferSummary?>(null) }
    var detail by remember { mutableStateOf<MemberOfferDetail?>(null) }
    var detailFailure by remember { mutableStateOf(false) }
    var review by remember { mutableStateOf<MemberReview?>(null) }
    var reviewFailure by remember { mutableStateOf(false) }
    var refreshGeneration by remember { mutableStateOf(0L) }
    var offerReloadGeneration by remember { mutableStateOf(0L) }
    var privateNodeState by remember { mutableStateOf(MemberPrivateNodeState.LOCKED) }
    var privateNodeNotice by remember { mutableStateOf(PrivateNodeNotice.NONE) }
    var privateNodeBusy by remember { mutableStateOf(false) }
    var refreshNotice by remember { mutableStateOf("") }
    var hintedRefresh by remember { mutableStateOf(false) }
    val accessSession = session?.takeIf { privateNodeState == MemberPrivateNodeState.READY }
    val privateNodeScope = rememberCoroutineScope()
    // The private node's own equivalent of iOS `MemberAccount.openPrivateNode`: distinguishes a
    // key mismatch (#41, `MemberFailure.KeyMismatch`) from any other, retryable failure, and
    // records which message the locked screen should show.
    suspend fun openPrivateNodeAttempt(info: MemberSessionInfo): MemberPrivateNodeState = try {
        val result = onOpenPrivateNode(info)
        privateNodeNotice = if (result == MemberPrivateNodeState.RECOVERY_REQUIRED) PrivateNodeNotice.RECOVERY_REQUIRED else PrivateNodeNotice.NONE
        result
    } catch (failure: Exception) {
        if (failure is CancellationException) throw failure
        privateNodeNotice = if (failure is MemberFailure.KeyMismatch) PrivateNodeNotice.KEY_MISMATCH else PrivateNodeNotice.TRANSIENT_FAILURE
        MemberPrivateNodeState.LOCKED
    }
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_STOP) {
                session = null; privateNodeState = MemberPrivateNodeState.LOCKED; privateNodeNotice = PrivateNodeNotice.NONE; offers = null; sourcesIncomplete = false; selectedOffer = null; detail = null; review = null
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
        offerFailure = false; sourcesIncomplete = false; selectedOffer = null; detail = null
        try {
            val result = onLoadOffers(current)
            offers = result.offers; sourcesIncomplete = result.incomplete
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
    // `offerReloadGeneration` is bumped by Done after a decision or statement is signed (#44):
    // the offer itself stays selected, and its detail and review are read again so the now
    // decided/settled state shows, without returning to the inbox list.
    LaunchedEffect(selectedOffer, accessSession, offerReloadGeneration) {
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
                    Text(stringResource(R.string.app_name), style = MaterialTheme.typography.headlineLarge, modifier = Modifier.semantics { heading() })
                    Text("Your household", style = MaterialTheme.typography.titleMedium)
                    if (session != null && privateNodeState != MemberPrivateNodeState.READY) {
                        // The locked screen always keeps a way out (#41): a retry for a read that
                        // merely failed, and Recovery / Sign out / Delete account / the account
                        // reference, all reachable from the Account tab regardless of this state.
                        MemberCard(
                            if (privateNodeState == MemberPrivateNodeState.RECOVERY_REQUIRED) "Recovery required" else "Private records are locked",
                            when (privateNodeNotice) {
                                PrivateNodeNotice.RECOVERY_REQUIRED -> stringResource(R.string.private_node_recovery_required_notice)
                                PrivateNodeNotice.KEY_MISMATCH -> stringResource(R.string.private_node_key_mismatch_notice)
                                else -> stringResource(R.string.private_node_generic_failure_notice)
                            },
                        ) {
                            // A key mismatch or recovery-required cannot be fixed by trying the same
                            // read again; only a transient failure (network, a dropped connection) can.
                            if (privateNodeState == MemberPrivateNodeState.LOCKED && privateNodeNotice == PrivateNodeNotice.TRANSIENT_FAILURE) {
                                TextButton(enabled = !privateNodeBusy, onClick = {
                                    val current = session
                                    if (current != null) {
                                        privateNodeBusy = true
                                        privateNodeScope.launch { privateNodeState = openPrivateNodeAttempt(current); privateNodeBusy = false }
                                    }
                                }) { Text(stringResource(R.string.private_node_try_again)) }
                            }
                        }
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
                        MemberDialsCard(
                            accessSession, onLoadEffectiveMandates, onLoadMandateChanges, onPrepareMandateChange, onPrepareMandateSignature, onApproveMandateChange, onCancelMandateChange,
                            onMandateSigned = { refreshGeneration++ },
                        )
                    } else if (selectedSection == "Account") {
                        when {
                            session == null -> MemberAccountCard(
                                onSignIn = onSignIn,
                                onRegister = onRegister,
                                onSignedIn = { info ->
                                    session = info; privateNodeState = openPrivateNodeAttempt(info)
                                    onSetHostMoveSession(info)
                                    refreshNotice = try {
                                        onRegisterRefresh(); "Private update notifications are enabled. Notifications contain no proposal details."
                                    } catch (_: Exception) { "Update notifications are unavailable. Foreground refresh remains available." }
                                    selectedSection = "Inbox"
                                    privateNodeState
                                },
                            )
                            accountSection == "Saved" -> MemberAccountSubScreen(title = stringResource(R.string.account_my_records), onBack = { accountSection = "Home" }) {
                                MemberSavedOperationsCard(accessSession, offers, onLoadSaved, onCheckSaved, onPrepareWithdrawal, onApproveWithdrawal, onCancelOperation)
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
                                                session = null; privateNodeState = MemberPrivateNodeState.LOCKED; privateNodeNotice = PrivateNodeNotice.NONE; onSetHostMoveSession(null); accountSection = "Home"
                                            }
                                        }
                                    },
                                )
                            }
                            accountSection == "Delete" -> MemberAccountSubScreen(title = stringResource(R.string.account_delete_account), onBack = { accountSection = "Home" }) {
                                // Deletion never touches the private node except locking it on
                                // success (`MemberLeaveFlow.deleteAccount`), so it stays reachable
                                // while the node is locked or needs recovery (#41): the way out a
                                // locked screen must keep.
                                MemberLeaveCard(
                                    session,
                                    onRefreshStatus = onRefreshLeaveStatus,
                                    onDeleteAccount = {
                                        onDeleteAccount().also {
                                            if (it.phase == MemberLeavePhase.DONE) {
                                                session = null; privateNodeState = MemberPrivateNodeState.LOCKED; privateNodeNotice = PrivateNodeNotice.NONE; onSetHostMoveSession(null); accountSection = "Home"
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
                                    session = null; privateNodeState = MemberPrivateNodeState.LOCKED; privateNodeNotice = PrivateNodeNotice.NONE; onSetHostMoveSession(null); selectedSection = "Account"; accountSection = "Home"
                                },
                            )
                        }
                    } else {
                        MemberInboxCard(
                            connected = accessSession != null,
                            offers = offers,
                            failed = offerFailure,
                            incomplete = sourcesIncomplete,
                            selectedOffer = selectedOffer,
                            detail = detail,
                            detailFailed = detailFailure,
                            review = review,
                            reviewFailed = reviewFailure,
                            session = accessSession,
                            onPrepareDecision = onPrepareDecision,
                            onApproveDecision = onApproveDecision,
                            // Done (#44) stays on this offer and reloads its detail and review,
                            // rather than returning to the inbox list (matches iOS's `reload` /
                            // `loadReview`: it pops one screen back and rereads that offer).
                            onDone = { offerReloadGeneration++ },
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
                Text(stringResource(R.string.account_move_host), style = MaterialTheme.typography.titleLarge)
                Text("Target", fontWeight = FontWeight.SemiBold)
                Text("The configured target host is trusted by this build. You will sign in there before anything is copied.")
                Text(memberHostMovePhaseText(state.phase), fontWeight = FontWeight.SemiBold)
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

/** Ported from ios/AtarasyPrototype/MemberAccountView.swift at 34cde26's `MemberHostMoveView.phase`. */
@Composable
private fun memberHostMovePhaseText(phase: MemberHostMovePhase) = stringResource(
    when (phase) {
        MemberHostMovePhase.IDLE -> R.string.host_move_phase_idle
        MemberHostMovePhase.SIGNING_INTO_TARGET -> R.string.host_move_phase_signing_into_target
        MemberHostMovePhase.EXPORTING -> R.string.host_move_phase_exporting
        MemberHostMovePhase.IMPORTING -> R.string.host_move_phase_importing
        MemberHostMovePhase.VERIFYING -> R.string.host_move_phase_verifying
        MemberHostMovePhase.READY_TO_RETIRE -> R.string.host_move_phase_ready_to_retire
        MemberHostMovePhase.RETIRING -> R.string.host_move_phase_retiring
        MemberHostMovePhase.COMPLETED -> R.string.host_move_phase_completed
        MemberHostMovePhase.SOURCE_RETAINED -> R.string.host_move_phase_source_retained
        MemberHostMovePhase.UNRESOLVED -> R.string.host_move_phase_unresolved
    },
)

/** Ported from ios/AtarasyPrototype/MemberAccountView.swift at 34cde26's `MemberLeaveSheet.blockerDescription`. */
@Composable
private fun describeLeaveBlocker(blocker: MemberLeaveBlocker) = stringResource(
    when (blocker.kind) {
        "offer_in_progress" -> R.string.leave_blocker_offer_in_progress
        "statement_unsigned" -> R.string.leave_blocker_statement_unsigned
        "reservation_held" -> R.string.leave_blocker_reservation_held
        "gift_in_flight" -> R.string.leave_blocker_gift_in_flight
        "permission_action_pending" -> R.string.leave_blocker_permission_action_pending
        "co_signer" -> R.string.leave_blocker_co_signer
        "recoverer" -> R.string.leave_blocker_recoverer
        "host_move_pending" -> R.string.leave_blocker_host_move_pending
        "operation_pending" -> R.string.leave_blocker_operation_pending
        "mandate_change_pending" -> R.string.leave_blocker_mandate_change_pending
        "recovery_request_pending" -> R.string.leave_blocker_recovery_request_pending
        "permission_request_pending" -> R.string.leave_blocker_permission_request_pending
        else -> R.string.leave_blocker_default
    },
)

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
    offers: List<MemberOfferSummary>?,
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
                    val label = memberRecordGoodsTitle(handle, offers)
                    Card(modifier = Modifier.fillMaxWidth()) {
                        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            Text(label, fontWeight = FontWeight.SemiBold)
                            Text(if (handle.attempted) stringResource(R.string.signed_and_sent) else stringResource(R.string.prepared_not_signed))
                            val checkingText = stringResource(R.string.label_checking)
                            val actionCheckResultText = stringResource(R.string.action_check_result)
                            val unreadableText = "The result could not be read. Check later and do not resubmit."
                            Button(enabled = checking == null, onClick = {
                                checking = handle.id; scope.launch {
                                    notices = notices + (handle.id to try { describeSaved(onCheck(handle)) } catch (failureValue: Exception) {
                                        if (failureValue is CancellationException) throw failureValue
                                        unreadableText
                                    })
                                    checking = null
                                }
                            }) { Text(if (checking == handle.id) checkingText else actionCheckResultText) }
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

/**
 * The goods on the offer, where the Inbox still lists it (`offers` is the same union
 * `MemberInboxCard` already loaded); a generic noun otherwise, never the raw operation or
 * offer id. Ported from iOS's `MemberRecordText.goods`.
 */
@Composable
private fun memberRecordGoodsTitle(handle: MemberOperationHandle, offers: List<MemberOfferSummary>?): String {
    val lines = offers?.firstOrNull { it.id == handle.offer }?.candidates
    val first = lines?.firstOrNull()
    return when {
        first == null -> stringResource(if (handle.operationProfile.contains("statement")) R.string.a_box else R.string.a_proposal)
        lines.size == 1 -> first.title
        else -> stringResource(R.string.inbox_row_and_more, first.title, lines.size - 1)
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
    onMandateSigned: () -> Unit = {},
) {
    var effective by remember(session) { mutableStateOf<List<Mandate>?>(null) }
    var changes by remember(session) { mutableStateOf<List<MemberMandateChange>?>(null) }
    var editing by remember(session) { mutableStateOf<Mandate?>(null) }
    var prepared by remember(session) { mutableStateOf<PreparedMemberMandateChange?>(null) }
    var outOfNetwork by remember(session) { mutableStateOf("") }
    var hasDaily by remember(session) { mutableStateOf(false) }
    var daily by remember(session) { mutableStateOf("") }
    var hasCooling by remember(session) { mutableStateOf(false) }
    var coolingHours by remember(session) { mutableStateOf(0) }
    var lapse by remember(session) { mutableStateOf(0L) }
    var showLapsePicker by remember(session) { mutableStateOf(false) }
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
    val validationText = stringResource(R.string.mandate_validation_message)
    fun begin(value: Mandate) {
        editing = value; prepared = null; outOfNetwork = value.ceilingOutOfNetwork.toString()
        hasDaily = value.ceilingDaily != null; daily = value.ceilingDaily?.toString().orEmpty()
        hasCooling = value.coolingSeconds != null; coolingHours = ((value.coolingSeconds ?: 0L) / 3_600L).toInt()
        lapse = value.lapsesAt; coSigners = value.coSigners.joinToString("\n")
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
                            Text(stringResource(R.string.mandate_new_limits_header), fontWeight = FontWeight.SemiBold)
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Checkbox(checked = hasDaily, onCheckedChange = { hasDaily = it })
                                Text(stringResource(R.string.mandate_daily_limit_label))
                            }
                            if (hasDaily) OutlinedTextField(daily, { daily = it }, label = { Text(stringResource(R.string.mandate_daily_amount_label)) }, singleLine = true)
                            OutlinedTextField(outOfNetwork, { outOfNetwork = it }, label = { Text(stringResource(R.string.mandate_outside_amount_label)) }, singleLine = true)
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Checkbox(checked = hasCooling, onCheckedChange = { hasCooling = it })
                                Text(stringResource(R.string.mandate_time_to_undo_label))
                            }
                            if (hasCooling) {
                                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                    TextButton(enabled = coolingHours > 0, onClick = { coolingHours-- }) { Text("−") }
                                    Text(if (coolingHours == 0) stringResource(R.string.limits_no_cooling) else MemberFormat.duration(coolingHours.toLong() * 3_600L))
                                    TextButton(enabled = coolingHours < 720, onClick = { coolingHours++ }) { Text("+") }
                                }
                            }
                            Text(stringResource(R.string.mandate_amounts_in, MemberFormat.currencyCode), style = MaterialTheme.typography.bodySmall, color = Color.Gray)
                            TextButton(onClick = { showLapsePicker = true }) { Text(stringResource(R.string.mandate_ends_on_label) + ": " + MemberFormat.day(lapse)) }
                            Text(stringResource(R.string.mandate_cosigners_header), fontWeight = FontWeight.SemiBold)
                            OutlinedTextField(coSigners, { coSigners = it }, label = { Text(stringResource(R.string.mandate_cosigners_hint)) })
                            Text(stringResource(R.string.mandate_cosigners_footer), style = MaterialTheme.typography.bodySmall, color = Color.Gray)
                            Text(stringResource(R.string.mandate_change_note), style = MaterialTheme.typography.bodySmall, color = Color.Gray)
                            Button(enabled = !busy, onClick = {
                                val proposal = try {
                                    val signers = coSigners.split('\n').map { it.trim() }.filter { it.isNotEmpty() }
                                    val outside = checkNotNull(outOfNetwork.toLongOrNull())
                                    val dailyValue = if (hasDaily) checkNotNull(daily.toLongOrNull()) else null
                                    require(coolingHours in 0..720)
                                    // A cooling period that was not a whole number of hours keeps its exact
                                    // value unless the member moved it (matches iOS's MemberMandateEditor).
                                    val originalCooling = base.coolingSeconds
                                    val cooling = if (hasCooling) {
                                        if (originalCooling != null && originalCooling / 3_600L == coolingHours.toLong()) originalCooling else coolingHours.toLong() * 3_600L
                                    } else null
                                    val candidate = Mandate(base.id, base.household, outside, dailyValue, cooling, signers, lapse, base.version + 1)
                                    Canonical.validateMandate(candidate); require(signers.distinct().size == signers.size)
                                    require(
                                        candidate.ceilingOutOfNetwork != base.ceilingOutOfNetwork || candidate.ceilingDaily != base.ceilingDaily ||
                                            candidate.coolingSeconds != base.coolingSeconds || candidate.coSigners != base.coSigners || candidate.lapsesAt != base.lapsesAt,
                                    )
                                    candidate
                                } catch (_: Exception) { notice = validationText; null }
                                if (proposal != null) {
                                    busy = true; scope.launch {
                                        try { prepared = onPrepare(proposal); notice = "Review every before/after protection and required signer before signing." }
                                        catch (failureValue: Exception) { if (failureValue is CancellationException) throw failureValue; notice = "The proposal could not be fixed. Refresh Dials before editing again." }
                                        busy = false
                                    }
                                }
                            }) { Text(stringResource(R.string.mandate_review_change)) }
                        }
                    }
                    if (showLapsePicker) {
                        MemberDatePickerDialog(initialMillis = lapse, onDismiss = { showLapsePicker = false }, onConfirm = { lapse = it; showLapsePicker = false })
                    }
                }
                Text(stringResource(R.string.limits_pending_changes_title), fontWeight = FontWeight.SemiBold)
                if (changes!!.isEmpty()) Text(stringResource(R.string.limits_no_pending))
                changes!!.forEach { change ->
                    Card(modifier = Modifier.fillMaxWidth()) {
                        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Text(stringResource(R.string.mandate_who_must_sign_header) + ": " + stringResource(R.string.mandate_signatures_count, change.signedBy.size, change.requiredSigners.size), fontWeight = FontWeight.SemiBold)
                            Text(stringResource(R.string.mandate_now_header) + ": " + describeMandate(change.before))
                            Text(stringResource(R.string.mandate_after_change_header) + ": " + describeMandate(change.mandate))
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
                            Text(stringResource(R.string.mandate_now_header) + ": " + describeMandate(fixed.change.before))
                            Text(stringResource(R.string.mandate_after_change_header) + ": " + describeMandate(fixed.change.mandate))
                            Text(stringResource(R.string.mandate_who_must_sign_header) + ": " + fixed.change.requiredSigners.size)
                            Button(enabled = !busy, onClick = { busy = true; scope.launch {
                                notice = when (val result = onApprove(fixed)) {
                                    // Signing an unsigned mandate version is what lets a presenter
                                    // deliver, so the inbox is read again here rather than waiting
                                    // for the member to pull (ios #44's onChange of the mandate list).
                                    is MemberDialsActionResult.Recorded -> { onMandateSigned(); if (result.change.state == "effective") recordedText else "Signature recorded. Waiting for required signers." }
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
    incomplete: Boolean,
    selectedOffer: MemberOfferSummary?,
    detail: MemberOfferDetail?,
    detailFailed: Boolean,
    review: MemberReview?,
    reviewFailed: Boolean,
    session: MemberSessionInfo?,
    onPrepareDecision: suspend (MemberSessionInfo, MemberOfferDetail, MemberApproval, Map<String, MemberDigitalChoice>) -> MemberDecisionReview,
    onApproveDecision: suspend (MemberDecisionReview) -> MemberDecisionActionResult,
    onDone: () -> Unit,
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
        selectedOffer != null -> MemberOfferDetailCard(detail, detailFailed, review, reviewFailed, session, onPrepareDecision, onApproveDecision, onPrepareStatement, onApproveStatement, onDone) { onSelect(null) }
        else -> Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
            // COPY-11: an empty section is never claimed as "nothing waiting" when every
            // source failed to answer at all (vault `80` §6.2 I).
            val nothingCouldBeChecked = incomplete && offers.isEmpty()
            if (incomplete) MemberCard(stringResource(R.string.inbox_sources_incomplete), "")
            MemberInboxSection(
                title = stringResource(R.string.inbox_section_at_home_title),
                subtitle = stringResource(R.string.inbox_section_at_home_subtitle),
                rows = offers.inboxRows("physical"),
                empty = if (nothingCouldBeChecked) stringResource(R.string.could_not_be_checked) else stringResource(R.string.inbox_empty_at_home),
                onSelect = onSelect,
            )
            MemberInboxSection(
                title = stringResource(R.string.inbox_section_proposals_title),
                subtitle = stringResource(R.string.inbox_section_proposals_subtitle),
                rows = offers.inboxRows("digital"),
                empty = if (nothingCouldBeChecked) stringResource(R.string.could_not_be_checked) else stringResource(R.string.inbox_empty_proposals),
                onSelect = onSelect,
            )
            if (offers.isEmpty() && !incomplete) MemberCard(stringResource(R.string.inbox_no_sources), "")
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
    onDone: () -> Unit,
    onBack: () -> Unit,
) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            TextButton(onClick = onBack) { Text("← " + stringResource(R.string.tab_inbox)) }
            when {
                failed -> { Text("Offer unavailable", style = MaterialTheme.typography.titleLarge); Text("This offer could not be loaded.") }
                detail == null -> { Text("Loading offer…", style = MaterialTheme.typography.titleLarge) }
                detail.binding == "physical" -> MemberBoxDetail(detail, review, reviewFailed, session, onPrepareStatement, onApproveStatement, onDone)
                else -> MemberProposalDetail(detail, review, reviewFailed, session, onPrepareDecision, onApproveDecision, onDone)
            }
        }
    }
}

/** A digital proposal (`22` UX-03). Ported from ios/AtarasyPrototype/MemberOfferScreen.swift's `MemberProposalView`. */
@Composable
private fun MemberProposalDetail(
    detail: MemberOfferDetail,
    review: MemberReview?,
    reviewFailed: Boolean,
    session: MemberSessionInfo?,
    onPrepareDecision: suspend (MemberSessionInfo, MemberOfferDetail, MemberApproval, Map<String, MemberDigitalChoice>) -> MemberDecisionReview,
    onApproveDecision: suspend (MemberDecisionReview) -> MemberDecisionActionResult,
    onDone: () -> Unit,
) {
    Text(MemberFormat.sellers(detail.candidates.map { it.merchant }), style = MaterialTheme.typography.titleLarge)
    detail.candidates.forEach { candidate ->
        Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(candidate.title, fontWeight = FontWeight.SemiBold)
            Text("${candidate.quantity} × " + MemberFormat.money(candidate.unitPrice))
            Text(stringResource(R.string.label_sold_by, candidate.merchant), style = MaterialTheme.typography.bodySmall, color = Color.Gray)
            Text(stringResource(R.string.label_made_by, candidate.maker), style = MaterialTheme.typography.bodySmall, color = Color.Gray)
            candidate.givenBy?.let { Text(stringResource(R.string.label_gift_from, it), style = MaterialTheme.typography.bodySmall, color = Color.Gray) }
            // Once the proposal has closed, each line says what became of it in the member's
            // own words rather than a raw protocol state (`MemberLineStatus.resolved`).
            if (detail.state != "presented") Text(memberDigitalResolvedStatus(candidate.valence), style = MaterialTheme.typography.bodySmall, color = Color.Gray)
        }
    }
    MemberTermsSection(detail.disclosures, collapsed = true)
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
            if (session != null && detail.state == "presented") MemberDigitalDecisionControls(session, detail, review.value, onPrepareDecision, onApproveDecision, onDone)
        }
        else -> {}
    }
}

/**
 * A box in the home (`22` UX-04, UX-05). Ported from
 * ios/AtarasyPrototype/MemberBoxScreen.swift at 34cde26: the collection records what
 * happened to each line, the member confirms that record or says a line is wrong, and
 * never picks "used" themselves (§11.2).
 */
@Composable
private fun MemberBoxDetail(
    detail: MemberOfferDetail,
    review: MemberReview?,
    reviewFailed: Boolean,
    session: MemberSessionInfo?,
    onPrepareStatement: suspend (MemberSessionInfo, MemberOfferDetail, MemberStatement, List<String>) -> MemberStatementReview,
    onApproveStatement: suspend (MemberStatementReview) -> MemberStatementActionResult,
    onDone: () -> Unit,
) {
    Text(MemberFormat.sellers(detail.candidates.map { it.merchant }), style = MaterialTheme.typography.titleLarge)
    if (detail.state == "presented") {
        Text(stringResource(R.string.status_next_swap, MemberFormat.day(detail.expiresAt)), style = MaterialTheme.typography.bodyMedium)
        Text(stringResource(R.string.box_at_home_note), style = MaterialTheme.typography.bodySmall, color = Color.Gray)
    } else {
        // §2.2b, §10a.5: the date is on the screen, and it is not the member's deadline.
        Text(stringResource(R.string.box_offered_until, MemberFormat.day(detail.expiresAt)), style = MaterialTheme.typography.bodyMedium)
        Text(stringResource(R.string.box_collected_note), style = MaterialTheme.typography.bodySmall, color = Color.Gray)
    }
    when {
        // A box the collection has not reached yet has no statement; its contents still show.
        reviewFailed -> MemberBoxContents(detail)
        review == null -> Text("Loading…")
        review is MemberReview.Statement -> {
            if (session != null) MemberBoxStatement(detail, review.value, session, onPrepareStatement, onApproveStatement, onDone)
            else MemberBoxContents(detail)
        }
        review is MemberReview.Settlement -> MemberBoxSettled(review.value, review.corrections, review.disclosures)
        else -> {}
    }
}

/** The box's lines from the offer itself, for a box the collection has not finished with. */
@Composable
private fun MemberBoxContents(detail: MemberOfferDetail) {
    Text(stringResource(R.string.box_in_the_box_title), style = MaterialTheme.typography.titleMedium)
    detail.candidates.forEach { candidate ->
        Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Row(horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth()) {
                Text(candidate.title)
                Text(if (candidate.givenBy == null) MemberFormat.money(MemberFormat.lineTotal(candidate.unitPrice, candidate.quantity)) else stringResource(R.string.box_free), color = Color.Gray)
            }
            candidate.givenBy?.let { Text(stringResource(R.string.label_gift_from, it), style = MaterialTheme.typography.bodySmall, color = Color.Gray) }
            Text(memberLineStatusWord(candidate.valence, candidate.collectedAs, detail.collectedAsSupplied), style = MaterialTheme.typography.bodySmall, color = Color.Gray)
        }
    }
    Text(stringResource(R.string.box_prices_note), style = MaterialTheme.typography.bodySmall, color = Color.Gray)
}

/** Question 3, 48: what a `lost` line says, and the box's other line-status words. */
@Composable
private fun memberLineStatusWord(valence: String, collectedAs: String?, collectedAsSupplied: Boolean): String {
    if (valence == "lost") return memberLostOutcome(collectedAs, collectedAsSupplied)
    return stringResource(
        when (valence) {
            "offered" -> R.string.line_status_with_you_not_collected
            "returned" -> R.string.line_status_went_back
            "consumed" -> R.string.line_status_used
            "kept" -> R.string.line_status_kept
            "defaulted" -> R.string.line_status_defaulted
            else -> R.string.line_status_with_you
        },
    )
}

/** A digital line once its proposal has closed (`MemberLineStatus.resolved`). */
@Composable
private fun memberDigitalResolvedStatus(valence: String): String = stringResource(
    when (valence) {
        "kept" -> R.string.line_status_kept
        "returned" -> R.string.line_status_declined
        "consumed" -> R.string.line_status_used
        "defaulted" -> R.string.line_status_defaulted
        else -> R.string.line_status_waiting
    },
)

@Composable
private fun memberLostOutcome(collectedAs: String?, supplied: Boolean): String = when {
    supplied && collectedAs == "missing" -> stringResource(R.string.lost_outcome_missing)
    supplied && collectedAs == null -> stringResource(R.string.lost_outcome_deadline)
    else -> stringResource(R.string.lost_outcome_unknown)
}

/**
 * The proposed statement, grouped by what the collection recorded (Used / Kept / Not found
 * in the box). Only a line recorded as used or missing can be marked, and a gift is free
 * whatever the collection recorded, so there is nothing on it to dispute.
 */
@Composable
private fun MemberBoxStatement(
    detail: MemberOfferDetail,
    statement: MemberStatement,
    session: MemberSessionInfo,
    onPrepare: suspend (MemberSessionInfo, MemberOfferDetail, MemberStatement, List<String>) -> MemberStatementReview,
    onApprove: suspend (MemberStatementReview) -> MemberStatementActionResult,
    onDone: () -> Unit,
) {
    var disputed by remember(detail.id) { mutableStateOf<Set<String>>(emptySet()) }
    var frozen by remember(detail.id) { mutableStateOf<MemberStatementReview?>(null) }
    // What the passkey signed, kept for the result: `22` UX-07, ios #44.
    var committed by remember(detail.id) { mutableStateOf(false) }
    var busy by remember(detail.id) { mutableStateOf(false) }
    var notice by remember(detail.id) { mutableStateOf("") }
    val scope = rememberCoroutineScope()
    // Read once per composition: never call stringResource() from inside a launched coroutine.
    val disputeConsumedText = stringResource(R.string.action_dispute)
    val disputeMissingText = stringResource(R.string.dispute_missing)
    val disputedText = stringResource(R.string.action_disputed)
    val notPreparedText = "The statement could not be prepared. Refresh the offer before trying again."
    val recordedText = stringResource(R.string.notice_statement_recorded)
    val cancelledText = stringResource(R.string.notice_signing_cancelled)
    val noCredentialText = stringResource(R.string.notice_no_credential)
    val unresolvedText = stringResource(R.string.notice_unresolved)
    val checkRecordsText = "Check your records before another action."

    val holdsNextBox = statement.lines.any { it.valence == "consumed" } ||
        (statement.lines.any { it.valence == "lost" } && statement.lines.any { it.valence == "kept" || it.valence == "defaulted" })
    if (frozen == null && holdsNextBox) MemberCard(stringResource(R.string.box_unsigned_hold), "")

    val activeStatement = frozen?.local?.statement ?: statement
    val activeDisputed = frozen?.local?.disputed?.toSet() ?: disputed
    MemberStatementGroup(
        stringResource(R.string.box_used), stringResource(R.string.statement_used_note),
        activeStatement.lines.filter { it.valence == "consumed" }, activeDisputed, frozen == null,
        disputable = { it.givenBy == null }, disputeLabel = disputeConsumedText, disputedLabel = disputedText,
        onToggle = { id -> disputed = if (id in disputed) disputed - id else disputed + id },
    )
    MemberStatementGroup(
        stringResource(R.string.box_kept), stringResource(R.string.statement_kept_note),
        activeStatement.lines.filter { it.valence == "kept" || it.valence == "defaulted" }, activeDisputed, editable = false,
        disputable = { false }, disputeLabel = "", disputedLabel = "", onToggle = {},
    )
    MemberStatementGroup(
        stringResource(R.string.box_missing), stringResource(R.string.statement_missing_note),
        activeStatement.lines.filter { it.valence == "lost" }, activeDisputed, frozen == null,
        disputable = { true }, disputeLabel = disputeMissingText, disputedLabel = disputedText,
        onToggle = { id -> disputed = if (id in disputed) disputed - id else disputed + id },
    )

    if (frozen == null) {
        val goodsLive = statement.lines.filter { it.valence != "lost" && it.candidate !in disputed }.sumOf { it.amount }
        MemberCard(stringResource(R.string.label_goods), "") {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                MemberAmountRow(stringResource(R.string.label_goods), MemberFormat.money(goodsLive))
                if (statement.carriage != null) {
                    MemberAmountRow(stringResource(R.string.label_delivery), MemberFormat.money(statement.carriage))
                    MemberAmountRow(stringResource(R.string.label_goods_and_delivery), MemberFormat.money(goodsLive + statement.carriage), emphasised = true)
                } else {
                    Text(stringResource(R.string.statement_not_ready_note), style = MaterialTheme.typography.bodySmall, color = Color.Gray)
                }
                if (disputed.isNotEmpty()) Text(stringResource(R.string.notice_disputed_lines_note), style = MaterialTheme.typography.bodySmall, color = Color.Gray)
            }
        }
        Button(enabled = !busy && statement.carriage != null, onClick = {
            busy = true; notice = ""; scope.launch {
                try { frozen = onPrepare(session, detail, statement, disputed.sorted()); notice = "" }
                catch (_: Exception) { notice = notPreparedText }
                busy = false
            }
        }) { Text(if (busy) stringResource(R.string.label_preparing) else stringResource(R.string.box_review_and_sign)) }
    } else if (committed) {
        // `22` UX-07, ios #44: show what was signed, and a Done that returns to this offer and
        // reloads it, rather than jumping back to the inbox with no confirmation of what happened.
        MemberSignedStatement(frozen!!)
        if (notice.isNotEmpty()) Text(notice)
        Button(onClick = onDone) { Text(stringResource(R.string.action_done)) }
    } else {
        val value = frozen!!
        Text(stringResource(R.string.sign_this_statement_title), style = MaterialTheme.typography.titleMedium)
        Text(stringResource(R.string.statement_signing_confirms, MemberFormat.sellers(activeStatement.lines.map { it.merchant })), style = MaterialTheme.typography.bodySmall, color = Color.Gray)
        MemberCard(stringResource(R.string.label_goods), "") {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                MemberAmountRow(stringResource(R.string.label_goods), MemberFormat.money(value.local.goodsCharged))
                MemberAmountRow(stringResource(R.string.label_delivery), MemberFormat.money(value.local.carriage))
                MemberAmountRow(stringResource(R.string.label_goods_and_delivery), MemberFormat.money(value.local.goodsCharged + value.local.carriage), emphasised = true)
                if (value.local.disputedGoods > 0) MemberAmountRow(stringResource(R.string.marked_not_right_not_charged), MemberFormat.money(value.local.disputedGoods))
            }
        }
        MemberTermsSection(activeStatement.disclosures, collapsed = false)
        if (activeStatement.lines.any { it.valence == "lost" }) {
            Text(stringResource(R.string.missing_attestation), style = MaterialTheme.typography.bodySmall, color = Color.Gray)
        }
        if (notice.isNotEmpty()) Text(notice)
        Button(enabled = !busy, onClick = {
            busy = true; notice = ""; scope.launch {
                when (val result = onApprove(value)) {
                    is MemberStatementActionResult.Outcome -> when (result.value) {
                        is MemberStatementOutcome.Committed -> { notice = recordedText; committed = true }
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
        }) { Text(if (busy) stringResource(R.string.label_signing) else stringResource(R.string.action_sign_with_passkey)) }
    }
    if (frozen == null && notice.isNotEmpty()) Text(notice)
}

/** What the member signed, under the result (`22` UX-07, ios #44): goods, delivery and any
 * disputed amount, using the same frozen values the pre-signing preview showed. */
@Composable
private fun MemberSignedStatement(value: MemberStatementReview) {
    MemberCard(stringResource(R.string.what_you_signed), "") {
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            MemberAmountRow(stringResource(R.string.label_goods), MemberFormat.money(value.local.goodsCharged))
            MemberAmountRow(stringResource(R.string.label_delivery), MemberFormat.money(value.local.carriage))
            if (value.local.disputedGoods > 0) MemberAmountRow(stringResource(R.string.marked_not_right_not_charged), MemberFormat.money(value.local.disputedGoods))
        }
    }
}

@Composable
private fun MemberStatementGroup(
    title: String,
    note: String,
    lines: List<MemberStatementLine>,
    disputedSet: Set<String>,
    editable: Boolean,
    disputable: (MemberStatementLine) -> Boolean,
    disputeLabel: String,
    disputedLabel: String,
    onToggle: (String) -> Unit,
) {
    if (lines.isEmpty()) return
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(title, style = MaterialTheme.typography.titleMedium)
            Text(note, style = MaterialTheme.typography.bodySmall, color = Color.Gray)
            lines.forEach { line ->
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Row(horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth()) {
                        Text(line.title)
                        Text(
                            when { line.valence == "lost" -> stringResource(R.string.amount_not_charged); line.givenBy != null -> stringResource(R.string.box_free); else -> MemberFormat.money(line.amount) },
                            color = Color.Gray,
                        )
                    }
                    Text(stringResource(R.string.label_sold_by, line.merchant), style = MaterialTheme.typography.bodySmall, color = Color.Gray)
                    if (line.maker != line.merchant) Text(stringResource(R.string.label_made_by, line.maker), style = MaterialTheme.typography.bodySmall, color = Color.Gray)
                    line.givenBy?.let { Text(stringResource(R.string.label_gift_from, it), style = MaterialTheme.typography.bodySmall, color = Color.Gray) }
                    line.note?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = Color.Gray) }
                    if (editable && disputable(line)) {
                        TextButton(onClick = { onToggle(line.candidate) }) {
                            Text(if (line.candidate in disputedSet) "$disputedLabel: ${line.title}" else disputeLabel)
                        }
                    }
                }
            }
        }
    }
}

/** A settled box. The signed settlement is never rewritten; a correction is appended
 * beside it (§6.6) and a returned refund is the shop's to repay off this platform (§6.6a). */
@Composable
private fun MemberBoxSettled(settlement: ProtocolSettlement, corrections: MemberCorrections?, disclosures: List<MemberDisclosure>) {
    Text(stringResource(R.string.settled_on, MemberFormat.day(settlement.settledAt)), style = MaterialTheme.typography.titleMedium)
    Text(stringResource(R.string.nothing_left_to_sign_box), style = MaterialTheme.typography.bodySmall, color = Color.Gray)
    MemberCard(stringResource(R.string.settled_goods_charged), "") {
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            settlement.lines.forEach { line ->
                Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
                    Row(horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth()) {
                        Text(line.title)
                        Text(if (line.valence == "lost") stringResource(R.string.amount_not_charged) else MemberFormat.money(line.amount), color = Color.Gray)
                    }
                    Text(memberLineStatusWord(line.valence, null, false), style = MaterialTheme.typography.bodySmall, color = Color.Gray)
                    if (line.disputed) {
                        Text(
                            if (line.valence == "lost") stringResource(R.string.said_in_box_note) else stringResource(R.string.marked_not_right_here_note),
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                }
            }
            MemberAmountRow(stringResource(R.string.settled_goods_charged), MemberFormat.money(settlement.charged), emphasised = true)
            if (settlement.disputedAmount > 0) MemberAmountRow(stringResource(R.string.marked_not_right_not_charged), MemberFormat.money(settlement.disputedAmount))
            Text(stringResource(R.string.payment_status_unavailable), style = MaterialTheme.typography.bodySmall, color = Color.Gray)
        }
    }
    corrections?.corrections?.takeIf { it.isNotEmpty() }?.let { rows ->
        MemberCard(stringResource(R.string.corrections_from_shop), stringResource(R.string.corrections_added_note)) {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                rows.forEach { correction ->
                    Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
                        Row(horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth()) {
                            Text(stringResource(if (correction.kind == "refund") R.string.refund_from else R.string.correction_from, correction.merchant))
                            Text("−" + MemberFormat.money(correction.amount), color = Color.Gray)
                        }
                        // The merchant's own words, as plain text and never as markup.
                        Text(correction.note, style = MaterialTheme.typography.bodySmall, color = Color.Gray)
                    }
                }
                MemberAmountRow(stringResource(R.string.after_corrections), MemberFormat.money(corrections.net), emphasised = true)
            }
        }
    }
    // SPEC §6.6a. A refund the issuer returned, or the shop's own repayment. This platform
    // moved no money either time and moves none now: the shop reaches the household by its
    // own signed contact, or, where it signed none, by the return terms already beside its
    // disclosure. Nothing here is sent to the merchant, and there is no refund action.
    corrections?.returns?.takeIf { it.isNotEmpty() }?.let { rows ->
        rows.forEach { ret ->
            Text(
                if (ret.state == "returned") "The refund from ${ret.merchant} did not reach you. The shop still owes it to you, off this platform." else "${ret.merchant} reports it repaid this another way.",
                style = MaterialTheme.typography.bodyMedium,
            )
            Text(ret.note, style = MaterialTheme.typography.bodySmall, color = Color.Gray)
            MerchantContactOrTerms(disclosures, ret.merchant)
        }
    }
    MemberTermsSection(disclosures, collapsed = true)
}

/**
 * `SPEC.md` §10a. Each merchant's signed text, as composed: never summarised, reordered or
 * translated. Collapsed per merchant while browsing, drawn open on a signing screen
 * (vault `80` D-7). Ported from ios/AtarasyPrototype/MemberOfferScreen.swift's `MemberTermsSection`.
 */
@Composable
private fun MemberTermsSection(blocks: List<MemberDisclosure>, collapsed: Boolean) {
    if (blocks.isEmpty()) return
    val merchants = remember(blocks) { blocks.map { it.merchant }.distinct() }
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(stringResource(R.string.shop_terms_title), style = MaterialTheme.typography.titleMedium)
        Text(stringResource(R.string.shop_terms_subtitle), style = MaterialTheme.typography.bodySmall, color = Color.Gray)
        merchants.forEach { merchant ->
            Card(modifier = Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (collapsed) {
                        var expanded by rememberSaveable(merchant) { mutableStateOf(false) }
                        TextButton(onClick = { expanded = !expanded }) { Text(stringResource(R.string.terms_from, merchant)) }
                        if (expanded) MemberTermsBlocks(blocks.filter { it.merchant == merchant })
                    } else {
                        Text(stringResource(R.string.terms_from, merchant), fontWeight = FontWeight.SemiBold)
                        MemberTermsBlocks(blocks.filter { it.merchant == merchant })
                    }
                }
            }
        }
    }
}

@Composable
private fun MemberTermsBlocks(blocks: List<MemberDisclosure>) {
    blocks.forEach { block ->
        block.product?.let { Text(stringResource(R.string.for_product_only, it), style = MaterialTheme.typography.labelSmall, color = Color.Gray) }
        block.items.forEach { item ->
            Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
                Text(item.label, style = MaterialTheme.typography.bodySmall, color = Color.Gray)
                Text(item.value, style = MaterialTheme.typography.bodyMedium)
            }
        }
        // Question 72. Only where this merchant signed one; tapping is the member's own act.
        block.contact?.let { ContactLink(it) }
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
private fun MemberDigitalDecisionControls(
    session: MemberSessionInfo,
    detail: MemberOfferDetail,
    approval: MemberApproval,
    onPrepare: suspend (MemberSessionInfo, MemberOfferDetail, MemberApproval, Map<String, MemberDigitalChoice>) -> MemberDecisionReview,
    onApprove: suspend (MemberDecisionReview) -> MemberDecisionActionResult,
    onDone: () -> Unit,
) {
    var choices by remember(detail.id) { mutableStateOf<Map<String, MemberDigitalChoice>>(emptyMap()) }
    var frozen by remember(detail.id) { mutableStateOf<MemberDecisionReview?>(null) }
    // What the passkey signed, kept for the result: `22` UX-07, ios #44.
    var committed by remember(detail.id) { mutableStateOf(false) }
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
        // `04b` §2.2c: the loss must be visible. Nothing is sent by choosing; only by signing.
        Text(stringResource(R.string.notice_choices_not_sent), style = MaterialTheme.typography.bodySmall, color = Color.Gray)
        Button(enabled = !busy && complete && approval.carriage != null, onClick = {
            busy = true; notice = ""
            scope.launch {
                try { frozen = onPrepare(session, detail, approval, choices); notice = "" }
                catch (_: Exception) { notice = notPreparedText }
                busy = false
            }
        }) { Text(if (busy) stringResource(R.string.label_preparing) else stringResource(R.string.action_review)) }
    } else if (committed) {
        // `22` UX-07, ios #44: the result said a decision was recorded but not what it was, and
        // had no way forward but the back arrow. Show the kept lines and the total, and a Done
        // that returns to this offer and reloads it, instead of jumping back to the inbox at once.
        MemberSignedDecision(frozen!!.frozen)
        if (notice.isNotEmpty()) Text(notice)
        Button(onClick = onDone) { Text(stringResource(R.string.action_done)) }
    } else {
        val value = frozen!!
        Text(
            MemberFormat.money(value.frozen.goods) + " · $deliveryText " + MemberFormat.money(value.frozen.carriage) + " · $totalText " + MemberFormat.money(value.frozen.total),
            fontWeight = FontWeight.SemiBold,
        )
        MemberTermsSection(value.frozen.approval.disclosures, collapsed = false)
        Button(enabled = !busy, onClick = {
            busy = true; notice = ""
            scope.launch {
                when (val result = onApprove(value)) {
                    is MemberDecisionActionResult.Outcome -> when (result.value) {
                        is MemberDecisionOutcome.Recorded -> { notice = recordedText; committed = true }
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
    if (!committed && notice.isNotEmpty()) Text(notice)
}

/** What the member signed, under its result (`22` UX-07, ios #44): the goods kept, and the total.
 * Ported from ios `MemberSignedDecision`. */
@Composable
private fun MemberSignedDecision(frozen: FrozenMemberDecision) {
    val kept = frozen.decisions.filter { it.valence == "kept" }.map { it.candidate }.toSet()
    val keptCandidates = frozen.approval.candidates.filter { it.id in kept }
    MemberCard(stringResource(R.string.what_you_signed), "") {
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            if (keptCandidates.isEmpty()) {
                Text(stringResource(R.string.nothing_declined_every_item), color = Color.Gray)
            } else {
                keptCandidates.forEach { candidate ->
                    Row(horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth()) {
                        Text(candidate.title)
                        Text(if (candidate.givenBy == null) MemberFormat.money(MemberFormat.lineTotal(candidate.unitPrice, candidate.quantity)) else stringResource(R.string.box_free))
                    }
                }
            }
            MemberAmountRow(stringResource(R.string.label_total), MemberFormat.money(frozen.total), emphasised = true)
        }
    }
}

/** A row of label and amount, ported from iOS's `MemberAmountRow`. */
@Composable
private fun MemberAmountRow(label: String, amount: String, emphasised: Boolean = false) {
    Row(horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth()) {
        Text(label, fontWeight = if (emphasised) FontWeight.Bold else FontWeight.Normal)
        Text(amount, fontWeight = if (emphasised) FontWeight.Bold else FontWeight.Normal)
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

/** The mandate editor's end date, as a calendar picker rather than a raw epoch text field. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MemberDatePickerDialog(initialMillis: Long, onDismiss: () -> Unit, onConfirm: (Long) -> Unit) {
    val state = rememberDatePickerState(initialSelectedDateMillis = initialMillis)
    DatePickerDialog(
        onDismissRequest = onDismiss,
        confirmButton = { TextButton(onClick = { state.selectedDateMillis?.let(onConfirm) ?: onDismiss() }) { Text(stringResource(android.R.string.ok)) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(android.R.string.cancel)) } },
    ) { DatePicker(state = state) }
}

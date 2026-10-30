// 화면 3 + 1(#338 B1 골격): 처음 설정 · 등록 대기/세션 · 대화방 목록 · 대화. 꾸밈 없이 코어 동작을 눌러 볼 수 있는 최소 UI — C 단계가 다듬는다.
// #574 PR 4: 등록 대기의 형제 승인 모드(큰 지문·만료) · 목록 위의 「새 기기 승인」 카드 · 「내 기기」(registrar 부여/해제).
// #584 PR 3: 처음 설정의 서버 주소는 도메인만 — 「서버 찾기」(`.well-known/hande`) 가 서버 이름·주소를 보여 준 뒤 저장, 목록 제목 아래 서버 이름.
// #584 Play 출시: 「설정」(정보 · 개인정보처리방침 · 계정 및 데이터 삭제 링크 · 「이 기기 지우기」) — 등록 대기·로그인·목록·오류 화면 어디서나 연다(Play 정책: 앱 안 링크 + 앱 내 삭제 경로).
//   Android 16(targetSdk 36)은 edge-to-edge 강제(adjustResize 무효) → 입력 화면은 `imePadding`, 뒤로가기는 `BackHandler`(predictive back 기본 켜짐).
// 한데 디자인 1차(2026-10-31, docs/design/HANDE-DESIGN-SYSTEM.md): 토큰은 `ui/theme/HandeTheme.kt`(`LocalHandeColors`), 모닥불 배경 위에 투명 Scaffold/앱바 ·
//   목록 = 「자리」(불 세기 불꽃 · 좌석 점 · 안 읽음 주황 점; 「불지기」 배지는 오너 결정 #613/#540 으로 없음) · 대화 = 말풍선(면/불/파랑) + 알약 입력창 · 설정 「화면」(밤/낮불).
package com.seoyoon_family.hande.ui

import android.content.Context
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Badge
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedCard
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Snackbar
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.inset
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.seoyoon_family.hande.BuildConfig
import com.seoyoon_family.hande.core.AgentActors
import com.seoyoon_family.hande.core.AppLogin
import com.seoyoon_family.hande.core.CandidateUi
import com.seoyoon_family.hande.core.DeviceHub
import com.seoyoon_family.hande.core.HandeThemeMode
import com.seoyoon_family.hande.core.HubUi
import com.seoyoon_family.hande.core.LoginLauncher
import com.seoyoon_family.hande.core.MessageUi
import com.seoyoon_family.hande.core.Phase
import com.seoyoon_family.hande.core.RoomUi
import com.seoyoon_family.hande.core.SelfService
import com.seoyoon_family.hande.core.ServerDiscovery
import com.seoyoon_family.hande.core.Settings
import com.seoyoon_family.hande.core.StatusUi
import com.seoyoon_family.hande.ui.theme.CampfireBackground
import com.seoyoon_family.hande.ui.theme.FlameIcon
import com.seoyoon_family.hande.ui.theme.LocalHandeColors
import com.seoyoon_family.hande.ui.theme.LogIcon
import com.seoyoon_family.hande.ui.theme.SeatDot
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 뿌리: 모닥불 배경(`CampfireBackground`) 위에 화면 하나. `themeMode`/`onThemeMode` 는 설정의 「화면」(밤/낮불) —
 * `MainActivity` 가 `HandeTheme` 모드를 바꾸고 `Settings.theme` 에 적는다(기본값은 다른 호출처가 그대로 컴파일되게 둔 것).
 */
@Composable
fun HandeRoot(hub: DeviceHub, themeMode: HandeThemeMode = HandeThemeMode.NIGHT, onThemeMode: (HandeThemeMode) -> Unit = {}) {
    val ui by hub.ui.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    var openRoom by rememberSaveable { mutableStateOf<String?>(null) }

    var showDevices by rememberSaveable { mutableStateOf(false) }
    var showSettings by rememberSaveable { mutableStateOf(false) }
    val settingsOpen = showSettings && ui.phase !is Phase.Setup

    // 시스템 뒤로가기(predictive back 포함): 설정 → 대화 → 내 기기 순으로 한 단계씩. 아무것도 열려 있지 않으면 기본 동작(앱 나가기).
    BackHandler(enabled = settingsOpen) { showSettings = false }
    BackHandler(enabled = !settingsOpen && openRoom != null) { openRoom = null }
    BackHandler(enabled = !settingsOpen && openRoom == null && showDevices) { showDevices = false }

    // 「이 기기 지우기」: 설정 화면과 등록 대기(409 `device_exists`, #574 후속)의 버튼이 같은 동작 — 열린 화면을 닫고 허브가 지운 뒤 처음 설정으로.
    val wipe: () -> Unit = { showSettings = false; openRoom = null; showDevices = false; hub.wipeDevice(scope) }

    CampfireBackground {
        if (settingsOpen) {
            SettingsScreen(ui, onBack = { showSettings = false }, onWipe = wipe, onNoticeShown = hub::clearNotice, themeMode = themeMode, onThemeMode = onThemeMode)
            return@CampfireBackground
        }
        when (val phase = ui.phase) {
            Phase.Setup -> SetupScreen(hub.settings, hub::discover) { hub.start(scope) }
            is Phase.WaitingEnrollment -> EnrollScreen(ui, phase, onSettings = { showSettings = true }, onWipe = wipe) { hub.retryEnrollment(scope) }
            Phase.NeedsLogin -> {
                val context = LocalContext.current
                LoginScreen(hub.settings, ui, onGoogle = { hub.beginLogin(context) }, onSaved = { hub.reconfigure(scope) }, onSettings = { showSettings = true }, onNoticeShown = hub::clearNotice)
            }
            is Phase.Fatal -> MessageScreen("앱을 시작할 수 없습니다", phase.message, action = { TextButton(onClick = { showSettings = true }) { Text(Strings.settingsButton) } })
            Phase.Starting -> MessageScreen(Strings.appName, Strings.starting)
            Phase.Ready -> {
                val room = openRoom?.let { name -> ui.rooms.firstOrNull { it.room == name } }
                if (room != null) {
                    // 보고 있는 방의 읽음 위치(#571 후속): 열 때 한 번, 그 뒤 마지막 seq 가 움직일 때마다(새 글·내 전송).
                    LaunchedEffect(room.room, room.messages.lastOrNull()?.seq) { hub.markRead(scope, room.room) }
                    RoomScreen(room, ui, onBack = { openRoom = null }, onSend = { text -> hub.send(scope, room.room, text) }, onNoticeShown = hub::clearNotice)
                } else if (showDevices) {
                    LaunchedEffect(Unit) { hub.refreshDevices(scope) }
                    DevicesScreen(ui, onBack = { showDevices = false }, onGrant = { hub.setRoles(scope, it, true) }, onRelease = { hub.setRoles(scope, it, false) }, onNoticeShown = hub::clearNotice)
                } else {
                    RoomListScreen(
                        ui, onOpen = { openRoom = it }, onRequestJoin = { hub.requestJoin(scope) },
                        onApprove = { hub.approve(scope, it) }, onIgnore = { hub.dismissCandidate(scope, it) }, onDevices = { showDevices = true },
                        onSettings = { showSettings = true }, onNoticeShown = hub::clearNotice,
                    )
                }
            }
        }
    }
}

/** 시각 한 줄(만료 표시). */
private fun clock(ms: Long): String = SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(ms))

@Composable
private fun MessageScreen(title: String, body: String, action: (@Composable () -> Unit)? = null) {
    Column(Modifier.fillMaxSize().safeDrawingPadding().padding(24.dp), verticalArrangement = Arrangement.Center) {
        Text(title, style = MaterialTheme.typography.titleLarge)
        Spacer(Modifier.height(12.dp))
        Text(body)
        if (action != null) {
            Spacer(Modifier.height(12.dp))
            action()
        }
    }
}

/** 정책 링크(#584 Play): 브라우저(Custom Tabs, 없으면 ACTION_VIEW)로 연다. 브라우저가 아예 없으면 `onFailed`. */
private fun openPolicy(context: Context, url: String, onFailed: () -> Unit) {
    try {
        LoginLauncher.open(context, url)
    } catch (_: AppLogin.Failure) {
        onFailed()
    }
}

/** 설정 화면·처음 설정의 정책 항목 한 줄(제목 · 설명 · 주소). 바탕은 투명(모닥불 배경). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PolicyLink(title: String, hint: String, url: String, onFailed: () -> Unit) {
    val context = LocalContext.current
    ListItem(
        headlineContent = { Text(title) },
        supportingContent = { Text(hint, style = MaterialTheme.typography.bodySmall) },
        overlineContent = { Text(url, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.labelSmall) },
        colors = ListItemDefaults.colors(containerColor = Color.Transparent),
        modifier = Modifier.fillMaxWidth().clickable { openPolicy(context, url, onFailed) },
    )
}

/**
 * 설정(#584 Play 출시): 정보(앱 버전·서버·기기 ID) · 정책 링크(개인정보처리방침 · 계정 및 데이터 삭제 — `BuildConfig`, 빌드 때 `HANDE_PRIVACY_URL`/`HANDE_DELETE_URL`) ·
 * 「이 기기 지우기」(확인 대화상자 → `DeviceHub.wipeDevice`). 계정 = CF Access 신원 + 릴레이 체인의 기기 기록이라 서버 쪽 폐기는 웹 안내로 요청한다(정직하게 적는다).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    ui: HubUi, onBack: () -> Unit, onWipe: () -> Unit, onNoticeShown: () -> Unit,
    themeMode: HandeThemeMode = HandeThemeMode.NIGHT, onThemeMode: (HandeThemeMode) -> Unit = {},
) {
    var confirmWipe by rememberSaveable { mutableStateOf(false) }
    var linkError by remember { mutableStateOf<String?>(null) }
    Scaffold(
        containerColor = Color.Transparent, contentColor = MaterialTheme.colorScheme.onBackground,
        topBar = { HandeTopBar(title = { Text(Strings.settingsTitle) }, navigationIcon = { TextButton(onClick = onBack) { Text(Strings.back) } }) },
        snackbarHost = { NoticeHost(ui.notice ?: linkError) { linkError = null; onNoticeShown() } },
    ) { pad ->
        Column(Modifier.padding(pad).fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            // 화면(한데 디자인 1차): 밤이 기본·고정(시스템 라이트 모드를 따르지 않는다), 낮불은 e-ink·밝은 곳용. 고르면 바로 바뀌고 `Settings.theme` 에 남는다.
            Text(Strings.themeSection, style = MaterialTheme.typography.titleMedium)
            ThemeChoice(Strings.themeNight, selected = themeMode == HandeThemeMode.NIGHT) { onThemeMode(HandeThemeMode.NIGHT) }
            ThemeChoice(Strings.themeDay, selected = themeMode == HandeThemeMode.DAY) { onThemeMode(HandeThemeMode.DAY) }
            Text(Strings.themeHint, style = MaterialTheme.typography.bodySmall)
            HorizontalDivider()
            Text(Strings.aboutSection, style = MaterialTheme.typography.titleMedium)
            Text(Strings.appVersion(BuildConfig.VERSION_NAME, BuildConfig.VERSION_CODE), style = MaterialTheme.typography.bodySmall)
            ui.server?.let { Text("${Strings.serverLabel}: $it", style = MaterialTheme.typography.bodySmall) }
            ui.deviceId?.let { Text(it, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall) }
            HorizontalDivider()
            Text(Strings.policySection, style = MaterialTheme.typography.titleMedium)
            PolicyLink(Strings.privacyPolicy, Strings.privacyPolicyHint, BuildConfig.PRIVACY_URL) { linkError = Strings.openLinkFailed }
            PolicyLink(Strings.deleteAccount, Strings.deleteAccountHint, BuildConfig.DELETE_ACCOUNT_URL) { linkError = Strings.openLinkFailed }
            HorizontalDivider()
            Text(Strings.wipeSection, style = MaterialTheme.typography.titleMedium)
            Text(Strings.wipeDeviceHint, style = MaterialTheme.typography.bodySmall)
            Button(
                onClick = { confirmWipe = true },
                colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error, contentColor = MaterialTheme.colorScheme.onError),
                modifier = Modifier.fillMaxWidth(),
            ) { Text(Strings.wipeDevice) }
        }
    }
    if (confirmWipe) WipeConfirmDialog(onConfirm = { confirmWipe = false; onWipe() }, onDismiss = { confirmWipe = false })
}

/** 「이 기기 지우기」 확인 대화상자 — 설정 화면과 등록 대기(ID 사용 불가)에서 같은 문구·같은 동작(#574 후속). */
@Composable
private fun WipeConfirmDialog(onConfirm: () -> Unit, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(Strings.wipeConfirmTitle) },
        text = { Text(Strings.wipeConfirmBody) },
        confirmButton = { TextButton(onClick = onConfirm) { Text(Strings.wipeConfirmButton, color = MaterialTheme.colorScheme.error) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(Strings.cancel) } },
    )
}

/** 투명 앱바 — 모닥불 배경이 비치게(한데 디자인 1차). 제목·버튼 색은 테마(onSurface = ink · primary = ember). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun HandeTopBar(title: @Composable () -> Unit, navigationIcon: @Composable () -> Unit = {}, actions: @Composable RowScope.() -> Unit = {}) {
    TopAppBar(
        title = title, navigationIcon = navigationIcon, actions = actions,
        colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.Transparent, scrolledContainerColor = Color.Transparent),
    )
}

/** 설정의 「화면」 한 줄(라디오 + 글자). 줄 전체가 눌린다(터치 44 이상). */
@Composable
private fun ThemeChoice(label: String, selected: Boolean, onSelect: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().selectable(selected = selected, onClick = onSelect, role = Role.RadioButton).padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RadioButton(selected = selected, onClick = null)
        Spacer(Modifier.width(8.dp))
        Text(label)
    }
}

/**
 * 처음 설정(#584 PR 3): 서버 주소는 도메인만 적어도 된다 — 「서버 찾기」가 `.well-known/hande` 로 릴레이를 찾아 서버 이름·주소를 카드로 보여 주고,
 * 「확인」이 그 결과(없으면 먼저 탐색해서)를 저장한다. 릴레이 주소(https://…)를 그대로 적은 옛 길은 문서가 없을 때의 폴백으로 그대로 된다.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SetupScreen(settings: Settings, onDiscover: suspend (String) -> ServerDiscovery.Result, onSaved: () -> Unit) {
    val scope = rememberCoroutineScope()
    var server by rememberSaveable { mutableStateOf(settings.relayUrl ?: "") }
    var actor by rememberSaveable { mutableStateOf(settings.actor ?: "") }
    var token by rememberSaveable { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var searching by remember { mutableStateOf(false) }
    var found by remember { mutableStateOf<ServerDiscovery.Result.Found?>(null) }

    fun save(f: ServerDiscovery.Result.Found) {
        settings.relayUrl = f.baseUrl
        settings.serverName = f.name
        if (settings.actor == null) settings.actor = actor.trim()
        if (token.isNotBlank()) settings.accessToken = token
        onSaved()
    }

    fun discover(then: ((ServerDiscovery.Result.Found) -> Unit)? = null) {
        if (searching) return
        searching = true; error = null; found = null
        scope.launch {
            val r = onDiscover(server)
            searching = false
            when (r) {
                is ServerDiscovery.Result.Found -> { found = r; then?.invoke(r) }
                ServerDiscovery.Result.BadInput -> error = Strings.serverBadInput
                is ServerDiscovery.Result.TooOld -> error = Strings.serverTooOld(r.required, r.current)
                is ServerDiscovery.Result.Unreachable -> error = Strings.serverUnreachable(r.baseUrl, r.detail)
            }
        }
    }

    Scaffold(containerColor = Color.Transparent, contentColor = MaterialTheme.colorScheme.onBackground, topBar = { HandeTopBar(title = { Text(Strings.setupTitle) }) }) { pad ->
        Column(Modifier.padding(pad).verticalScroll(rememberScrollState()).imePadding().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            OutlinedTextField(server, { server = it; found = null }, label = { Text(Strings.serverField) }, supportingText = { Text(Strings.serverHint) }, singleLine = true, modifier = Modifier.fillMaxWidth(), enabled = !searching)
            TextButton(onClick = { discover() }, enabled = !searching && server.isNotBlank()) { Text(if (searching) Strings.findingServer else Strings.findServer) }
            found?.let { f ->
                Card(Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(f.name ?: Strings.serverUnnamed, style = MaterialTheme.typography.titleMedium)
                        Text(f.baseUrl, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall)
                        Text(if (f.wellKnown != null) Strings.serverViaWellKnown else Strings.serverDirect, style = MaterialTheme.typography.bodySmall)
                        if (!f.healthOk) Text(Strings.serverGated, style = MaterialTheme.typography.bodySmall)
                    }
                }
            }
            Text(Strings.actorTitle, style = MaterialTheme.typography.titleMedium)
            OutlinedTextField(actor, { actor = it.lowercase() }, label = { Text(Strings.actorField) }, supportingText = { Text(Strings.actorHint) }, singleLine = true, modifier = Modifier.fillMaxWidth(), enabled = settings.actor == null)
            OutlinedTextField(token, { token = it }, label = { Text(Strings.tokenField) }, supportingText = { Text(Strings.tokenHint) }, singleLine = true, modifier = Modifier.fillMaxWidth())
            error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            Button(enabled = !searching, onClick = {
                val f = found
                when {
                    settings.actor == null && !Settings.validActor(actor.trim()) -> error = Strings.actorInvalid
                    f != null -> save(f) // 「서버 찾기」로 이미 확인한 서버
                    else -> discover { save(it) } // 바로 「확인」: 탐색부터 하고 성공하면 저장
                }
            }) { Text(Strings.save) }
            // 로그인 전에도 보이는 정책 링크(#584 Play: 개인정보처리방침은 앱 안에서 열려야 한다). 삭제 안내는 설정 화면에도 있다.
            HorizontalDivider()
            PolicyLink(Strings.privacyPolicy, Strings.privacyPolicyHint, BuildConfig.PRIVACY_URL) { error = Strings.openLinkFailed }
            PolicyLink(Strings.deleteAccount, Strings.deleteAccountHint, BuildConfig.DELETE_ACCOUNT_URL) { error = Strings.openLinkFailed }
        }
    }
}

/**
 * 등록 대기(#574): SIBLING 모드는 큰 지문(4자 묶음)과 만료 시각 — 같은 사람의 다른 기기가 「새 기기 승인」에서 견주어 승인한다.
 * OPERATOR(첫 기기·옛 릴레이)·ID_TAKEN 은 오늘의 운영자 JSON 화면; SIBLING 에서도 접어 둔 운영자 정보를 펼 수 있다.
 * ID_TAKEN(409 `device_exists`, #574 후속)에는 「이 기기 지우기 / 새 ID로 다시 시작」 — 설정 화면의 「이 기기 지우기」와 같은 확인 대화상자·같은 동작(`onWipe`).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun EnrollScreen(ui: HubUi, phase: Phase.WaitingEnrollment, onSettings: () -> Unit, onWipe: () -> Unit, onRetry: () -> Unit) {
    val clipboard = LocalClipboardManager.current
    var copied by remember { mutableStateOf(false) }
    var operatorShown by rememberSaveable { mutableStateOf(false) }
    var confirmWipe by rememberSaveable { mutableStateOf(false) }
    val sibling = phase.mode == SelfService.EnrollMode.SIBLING
    val json = phase.json
    Scaffold(
        containerColor = Color.Transparent, contentColor = MaterialTheme.colorScheme.onBackground,
        topBar = { HandeTopBar(title = { Text(if (sibling) Strings.enrollSiblingTitle else Strings.enrollTitle) }, actions = { TextButton(onClick = onSettings) { Text(Strings.settingsButton) } }) },
    ) { pad ->
        Column(Modifier.padding(pad).verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            when (phase.mode) {
                SelfService.EnrollMode.SIBLING -> Text(Strings.enrollSiblingBody)
                SelfService.EnrollMode.ID_TAKEN -> {
                    Text(Strings.enrollIdTaken, color = MaterialTheme.colorScheme.error)
                    Button(
                        onClick = { confirmWipe = true },
                        colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error, contentColor = MaterialTheme.colorScheme.onError),
                        modifier = Modifier.fillMaxWidth(),
                    ) { Text(Strings.wipeAndRestart) }
                }
                SelfService.EnrollMode.OPERATOR -> Text(Strings.enrollBody)
            }
            Text(Strings.fingerprintLabel, style = MaterialTheme.typography.labelLarge)
            if (sibling) {
                Card { Text(SelfService.groupedFingerprint(ui.fingerprint ?: ""), Modifier.padding(16.dp), fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.titleLarge) }
            } else {
                Text(ui.fingerprint ?: "", fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall)
            }
            Text(ui.deviceId ?: "", fontFamily = FontFamily.Monospace)
            if (sibling) {
                phase.expiresAt?.let { Text(Strings.enrollSiblingExpires(clock(it)), style = MaterialTheme.typography.bodySmall) }
                TextButton(onClick = { operatorShown = !operatorShown }) { Text(if (operatorShown) Strings.hideOperatorInfo else Strings.showOperatorInfo) }
            } else if (phase.mode == SelfService.EnrollMode.OPERATOR) {
                Text(Strings.enrollOperatorOnly, style = MaterialTheme.typography.bodySmall)
            }
            if (!sibling || operatorShown) {
                Card { Text(json, Modifier.padding(12.dp), fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall) }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(onClick = { clipboard.setText(AnnotatedString(json)); copied = true }) { Text(if (copied) Strings.copied else Strings.copyRegistration) }
                    TextButton(onClick = onRetry) { Text(Strings.enrolledButton) }
                }
            }
            Text(Strings.waitingOperator, style = MaterialTheme.typography.bodySmall)
        }
    }
    if (confirmWipe) WipeConfirmDialog(onConfirm = { confirmWipe = false; onWipe() }, onDismiss = { confirmWipe = false })
}

/** 우편함의 새 기기 승인 카드(#574): 지문을 크게, 「지문 비교 후 승인」·「무시」(프로세스가 다시 떠도 숨김 — 후보 TTL 뒤 만료). 실패 사유는 카드 안에. */
@Composable
private fun CandidateCard(c: CandidateUi, onApprove: () -> Unit, onIgnore: () -> Unit) {
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(c.deviceId, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.titleSmall)
            Text(SelfService.groupedFingerprint(c.fingerprint), fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodyLarge)
            c.expiresAt?.let { Text(Strings.candidateExpires(clock(it)), style = MaterialTheme.typography.bodySmall) }
            c.message?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = onApprove, enabled = !c.busy) { Text(if (c.busy) Strings.approving else Strings.approveButton) }
                TextButton(onClick = onIgnore, enabled = !c.busy) { Text(Strings.ignoreButton) }
            }
        }
    }
}

/** 「내 기기」(#574 E5): 체인의 내 기기 전부(이 기기 먼저) — 상태·등록 기기 표시·지문, 허용될 때만 부여/해제 버튼. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DevicesScreen(ui: HubUi, onBack: () -> Unit, onGrant: (String) -> Unit, onRelease: (String) -> Unit, onNoticeShown: () -> Unit) {
    Scaffold(
        containerColor = Color.Transparent, contentColor = MaterialTheme.colorScheme.onBackground,
        topBar = { HandeTopBar(title = { Text(Strings.devicesTitle) }, navigationIcon = { TextButton(onClick = onBack) { Text(Strings.back) } }) },
        snackbarHost = { NoticeHost(ui.notice, onNoticeShown) },
    ) { pad ->
        val view = ui.devices
        Column(Modifier.padding(pad).fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(Strings.devicesHint, style = MaterialTheme.typography.bodySmall)
            if (view == null || view.devices.isEmpty()) {
                Text(Strings.devicesEmpty)
            } else {
                for (d in view.devices) {
                    Card(Modifier.fillMaxWidth()) {
                        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                Text(d.deviceId, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.titleSmall)
                                if (d.isSelf) Badge { Text(Strings.thisDevice) }
                                if (d.registrar) Badge { Text(Strings.registrarPill) }
                            }
                            Text(
                                if (d.status == SelfService.STATUS_ACTIVE) Strings.statusActive else "${Strings.statusRevoked} · ${d.status}",
                                style = MaterialTheme.typography.bodySmall,
                                color = if (d.status == SelfService.STATUS_ACTIVE) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.error,
                            )
                            Text(SelfService.groupedFingerprint(d.fingerprint), fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall)
                            when {
                                d.grant -> TextButton(onClick = { onGrant(d.deviceId) }) { Text(Strings.grantButton) }
                                d.release -> TextButton(onClick = { onRelease(d.deviceId) }) { Text(Strings.releaseButton) }
                                d.lastRegistrar -> Text(Strings.lastRegistrarNote, style = MaterialTheme.typography.bodySmall)
                            }
                        }
                    }
                }
            }
        }
    }
}

/** 가족 로그인(B2, iOS LoginView 와 같은 구성): 「Google 계정으로 로그인」이 주 경로, 세션 값 붙여넣기는 운영자용으로 접어 둔다. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LoginScreen(settings: Settings, ui: HubUi, onGoogle: () -> Unit, onSaved: () -> Unit, onSettings: () -> Unit, onNoticeShown: () -> Unit) {
    var token by rememberSaveable { mutableStateOf("") }
    var manualExpanded by rememberSaveable { mutableStateOf(false) }
    Scaffold(
        containerColor = Color.Transparent, contentColor = MaterialTheme.colorScheme.onBackground,
        topBar = { HandeTopBar(title = { Text(Strings.loginTitle) }, actions = { TextButton(onClick = onSettings) { Text(Strings.settingsButton) } }) },
        snackbarHost = { NoticeHost(ui.notice, onNoticeShown) },
    ) { pad ->
        Column(Modifier.padding(pad).verticalScroll(rememberScrollState()).imePadding().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Button(onClick = onGoogle, enabled = settings.relayUrl != null, modifier = Modifier.fillMaxWidth()) { Text(Strings.loginGoogle) }
            Text(Strings.loginHint, style = MaterialTheme.typography.bodySmall)
            HorizontalDivider()
            TextButton(onClick = { manualExpanded = !manualExpanded }) { Text(Strings.loginManualTitle) }
            if (manualExpanded) {
                OutlinedTextField(token, { token = it }, label = { Text(Strings.loginField) }, singleLine = true, modifier = Modifier.fillMaxWidth(), visualTransformation = PasswordVisualTransformation())
                Button(enabled = token.isNotBlank(), onClick = { settings.accessToken = token; token = ""; onSaved() }) { Text(Strings.loginButton) }
                Text(Strings.loginManualHint, style = MaterialTheme.typography.bodySmall)
            }
        }
    }
}

/**
 * 대화 목록 = 「자리」(한데 디자인 1차): 머리(제목 · 「오늘 밤, 모닥불에 한데 모여」 · 서버 이름) + 방 행 카드(`RoomRow`).
 * 머리는 TopAppBar 대신 본문 위에 그린다 — Display 32 + 보조 두 줄은 64dp 앱바에 들어가지 않는다. 초대 벨·순서 편집·「불 피우기」는 Android 에 그 데이터/동작이 없어 두지 않는다.
 */
@Composable
fun RoomListScreen(
    ui: HubUi, onOpen: (String) -> Unit, onRequestJoin: () -> Unit,
    onApprove: (String) -> Unit, onIgnore: (String) -> Unit, onDevices: () -> Unit, onSettings: () -> Unit, onNoticeShown: () -> Unit,
) {
    val colors = LocalHandeColors.current
    Scaffold(
        containerColor = Color.Transparent, contentColor = MaterialTheme.colorScheme.onBackground,
        snackbarHost = { NoticeHost(ui.notice, onNoticeShown) },
    ) { pad ->
        Column(Modifier.padding(pad).fillMaxSize()) {
            Row(Modifier.fillMaxWidth().padding(start = 20.dp, end = 8.dp, top = 12.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(Strings.roomsTitle, style = MaterialTheme.typography.headlineLarge)
                    // 연결 중이면 부제 자리에 그 사실을(제목은 그대로 「자리」).
                    Text(if (ui.connecting) Strings.connecting else Strings.campfireSubtitle, style = MaterialTheme.typography.bodySmall, color = colors.inkDim)
                    // 제목 아래 서버 이름(#584): `.well-known` 의 이름, 없으면 릴레이 호스트 — 다른 운영자의 서버에 붙었을 때 어디인지 보인다.
                    ui.server?.let { Text(it, style = MaterialTheme.typography.labelSmall, color = colors.inkDim, maxLines = 1, overflow = TextOverflow.Ellipsis) }
                }
                TextButton(onClick = onDevices) { Text(Strings.devicesButton) }
                TextButton(onClick = onSettings) { Text(Strings.settingsButton) }
            }
            // 새 기기 승인 요청(#574): 등록 기기(또는 registrar 없는 actor 의 활성 기기)에게만 보인다.
            if (ui.candidates.isNotEmpty()) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(Strings.candidatesTitle, style = MaterialTheme.typography.titleMedium)
                    Text(Strings.candidatesHint, style = MaterialTheme.typography.bodySmall)
                    for (c in ui.candidates) CandidateCard(c, onApprove = { onApprove(c.deviceId) }, onIgnore = { onIgnore(c.deviceId) })
                }
                HorizontalDivider(color = colors.stroke)
            }
            if (ui.rooms.isEmpty()) {
                Text(Strings.noRooms, Modifier.padding(16.dp), color = colors.inkDim)
            } else {
                LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(vertical = 6.dp)) {
                    items(ui.rooms, key = { it.room }) { r -> RoomRow(r) { onOpen(r.room) } }
                }
            }
            if (ui.rooms.isEmpty()) Spacer(Modifier.weight(1f))
            HorizontalDivider(color = colors.stroke)
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("${ui.deviceId ?: ""}", fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall, color = colors.inkDim)
                Text("${Strings.lobbyKeys} ${ui.lobbyLive ?: "-"}/${ui.lobbyMax ?: "-"} · ${Strings.keyCustody}: ${ui.keyCustody ?: "-"}", style = MaterialTheme.typography.bodySmall, color = colors.inkDim)
                Button(onClick = onRequestJoin, modifier = Modifier.fillMaxWidth()) { Text(Strings.requestJoin) }
            }
        }
    }
}

/**
 * 방 행 카드: 원형 아이콘(불 세기 1~3단 불꽃 / 꺼진 자리는 장작) · 이름 · 미리보기 · 좌석 점 · 안 읽음 주황 점(개수 없음).
 * 「불지기」 배지는 목록에 넣지 않는다(오너 2026-10-31 iOS #613 · 웹 #540 — 디자인 1차 1b 보다 이 결정이 우선). 에이전트는 좌석 점의 파란 점으로 보인다.
 * 「오늘의 불 세기」는 시각이 화면 모델에 없어(`MessageUi` 에 received_at 없음) 보관된 글 수로 가늠한다 — 12건 이상 3단 · 3건 이상 2단 · 그 밖 1단. 숫자는 보이지 않는다.
 * 꺼진 자리 = 60% 흐림 + 장작 + 「불이 꺼진 자리 · 운영자가 닫음」(`room_closed` 일 때만 — 다른 정지 사유는 토큰을 그대로 적는다).
 */
@Composable
private fun RoomRow(r: RoomUi, onOpen: () -> Unit) {
    val colors = LocalHandeColors.current
    val halted = r.halted != null
    val shape = RoundedCornerShape(16.dp)
    val level = when {
        r.messages.size >= 12 -> 3
        r.messages.size >= 3 -> 2
        else -> 1
    }
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 5.dp)
            .alpha(if (halted) 0.6f else 1f)
            .clip(shape)
            .background(colors.surface)
            .border(colors.lineWidth, colors.stroke, shape)
            .clickable(onClick = onOpen)
            .padding(horizontal = 14.dp, vertical = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(48.dp).clip(CircleShape).background(colors.ember.copy(alpha = if (halted) 0.06f else 0.12f)), contentAlignment = Alignment.Center) {
            if (halted) LogIcon() else FlameIcon(level, dim = false, contentDescription = Strings.fireLevel(level))
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(r.room, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
            }
            Spacer(Modifier.height(2.dp))
            val working = r.working
            val preview = when {
                halted -> if (r.halted == "room_closed") Strings.roomClosedPreview else "${Strings.halted} · ${r.halted}"
                !r.joined -> Strings.notJoined
                // status-v1(#560): 에이전트가 일하는 중이면 미리보기 자리에 최신 「⏳ Working …」 줄(오너 2026-10-30).
                working != null -> working
                else -> r.messages.lastOrNull()?.text ?: ""
            }
            val workingShown = !halted && r.joined && working != null
            Text(
                preview, style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis,
                color = if (workingShown) colors.ember else colors.inkDim, fontWeight = if (workingShown) FontWeight.SemiBold else FontWeight.Normal,
            )
            SeatDots(r.messages)
        }
        // 안 읽음(#571 후속): 주황 점 하나(개수 없음) — 글자는 접근성 문구로만. 같은 사람의 다른 기기(PC 웹·iPhone)에서 읽으면 다음 poll 에 꺼진다.
        if (r.unread) {
            Spacer(Modifier.width(8.dp))
            Box(Modifier.size(10.dp).clip(CircleShape).background(colors.ember).semantics { contentDescription = Strings.unread })
        }
    }
}

/**
 * 좌석 점 줄: 글을 쓴 사람(actor 단위 — 같은 사람의 여러 기기는 한 점, 최대 5) 크림 ● 뒤에 에이전트(노드 단위) 파랑 ● — 합쳐 최대 6.
 * Android 는 명단(roster)을 받지 않으므로 보관된 글의 보낸 이로 가늠한다. 아무도 없으면 그리지 않는다.
 */
@Composable
private fun SeatDots(messages: List<MessageUi>) {
    val people = LinkedHashSet<String>()
    val agents = LinkedHashSet<String>()
    for (m in messages) {
        if (AgentActors.isAgentDevice(m.sender)) agents += AgentActors.agentNode(m.sender) else people += AgentActors.actorOf(m.sender)
    }
    val personCount = minOf(people.size, 5)
    val agentCount = minOf(agents.size, 6 - personCount)
    if (personCount + agentCount == 0) return
    Row(Modifier.padding(top = 6.dp), horizontalArrangement = Arrangement.spacedBy(5.dp), verticalAlignment = Alignment.CenterVertically) {
        repeat(personCount) { SeatDot(agent = false) }
        repeat(agentCount) { SeatDot(agent = true) }
    }
}

/** 대화방(한데 디자인 1차): 말풍선(`MessageRow`) · 작업 상태(`StatusRow`) · 알약 입력창 + 주황 보내기 원(`Composer`). 정지된 방은 `warn` 색 한 줄 + 사유. */
@Composable
fun RoomScreen(room: RoomUi, ui: HubUi, onBack: () -> Unit, onSend: (String) -> Unit, onNoticeShown: () -> Unit) {
    val colors = LocalHandeColors.current
    var draft by rememberSaveable(room.room) { mutableStateOf("") }
    val listState = rememberLazyListState()
    // 맨 아래 따라가기: 새 글이나 작업 상태 말풍선이 생기면(사라질 때는 아님) 마지막 항목으로.
    val total = room.messages.size + room.statuses.size
    LaunchedEffect(room.messages.size, room.statuses.size) { if (total > 0) listState.animateScrollToItem(total - 1) }
    Scaffold(
        containerColor = Color.Transparent, contentColor = MaterialTheme.colorScheme.onBackground,
        topBar = {
            HandeTopBar(
                title = { Text(if (ui.connecting) Strings.connecting else room.room) },
                navigationIcon = { TextButton(onClick = onBack) { Text(Strings.back) } },
            )
        },
        snackbarHost = { NoticeHost(ui.notice, onNoticeShown) },
    ) { pad ->
        Column(Modifier.padding(pad).fillMaxSize().imePadding()) {
            LazyColumn(Modifier.weight(1f).fillMaxWidth(), state = listState, contentPadding = PaddingValues(12.dp)) {
                items(room.messages, key = { "${it.sender}-${it.seq}" }) { m -> MessageRow(m) }
                // status-v1(#560): 보낸이별 임시 말풍선 하나 — 키가 보낸이라 제자리에서 본문만 바뀐다.
                items(room.statuses, key = { "status:${it.sender}" }) { s -> StatusRow(s) }
            }
            if (room.halted != null) {
                Text("${Strings.halted} · ${room.halted}", Modifier.padding(12.dp), color = colors.warn)
            } else if (!room.joined) {
                Text(Strings.notJoined, Modifier.padding(12.dp), color = colors.inkDim)
            } else {
                Composer(draft, onDraft = { draft = it }, onSend = { onSend(draft.trim()); draft = "" })
            }
        }
    }
}

/** 입력창(알약, 면+선) + 보내기(44dp 주황 원 「↑」, 비면 35%). 화면에서 큰 주황 면은 내 말풍선과 이 버튼뿐. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun Composer(draft: String, onDraft: (String) -> Unit, onSend: () -> Unit) {
    val colors = LocalHandeColors.current
    val canSend = draft.isNotBlank()
    Row(Modifier.padding(horizontal = 12.dp, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.Bottom) {
        OutlinedTextField(
            draft, onDraft, Modifier.weight(1f),
            placeholder = { Text(Strings.composerPlaceholder) }, maxLines = 4,
            shape = RoundedCornerShape(23.dp),
            colors = OutlinedTextFieldDefaults.colors(
                focusedBorderColor = colors.focus, unfocusedBorderColor = colors.stroke,
                focusedContainerColor = colors.surface, unfocusedContainerColor = colors.surface,
                cursorColor = colors.ember, focusedTextColor = colors.ink, unfocusedTextColor = colors.ink,
                focusedPlaceholderColor = colors.inkDim, unfocusedPlaceholderColor = colors.inkDim,
            ),
        )
        Box(
            Modifier
                .padding(bottom = 6.dp)
                .size(44.dp)
                .clip(CircleShape)
                .background(if (canSend) colors.ember else colors.ember.copy(alpha = 0.35f))
                .clickable(enabled = canSend, role = Role.Button, onClick = onSend)
                .semantics { contentDescription = Strings.sendButton },
            contentAlignment = Alignment.Center,
        ) { Text("↑", color = colors.onEmber, fontWeight = FontWeight.Bold, fontSize = 20.sp) }
    }
}

/**
 * 말풍선: 남 = 면+선(꼬리 왼쪽 아래 6) · 나 = 불(꼬리 오른쪽 아래 6) · 에이전트 = 파랑 fill 10% + stroke 35%(낮불: 흰 면 + 파랑 점선 1.5).
 * 보낸 이 라벨 = 좌석 점 + 이름(에이전트는 「공명 · 불지기」 파랑). 너비는 82% 까지. 첨부는 본문의 자리 표시 글 그대로(C 단계).
 */
@Composable
private fun MessageRow(m: MessageUi) {
    val colors = LocalHandeColors.current
    val agent = !m.mine && AgentActors.isAgentDevice(m.sender)
    Column(Modifier.fillMaxWidth().padding(vertical = 3.dp), horizontalAlignment = if (m.mine) Alignment.End else Alignment.Start) {
        if (!m.mine) {
            val name = AgentActors.displayName(m.sender)
            Row(Modifier.padding(start = 4.dp, bottom = 3.dp), verticalAlignment = Alignment.CenterVertically) {
                SeatDot(agent, 7.dp)
                Spacer(Modifier.width(4.dp))
                Text(if (agent) "$name · ${Strings.agentBadge}" else name, style = MaterialTheme.typography.bodySmall, color = if (agent) colors.agentText else colors.inkDim)
            }
        }
        val shape = if (m.mine) RoundedCornerShape(18.dp, 18.dp, 6.dp, 18.dp) else RoundedCornerShape(18.dp, 18.dp, 18.dp, 6.dp)
        val fill = when {
            m.mine -> Modifier.background(colors.ember)
            agent && colors.isDay -> Modifier.background(colors.surface).dashedBorder(1.5.dp, colors.agent, shape)
            agent -> Modifier.background(colors.agent.copy(alpha = 0.10f)).border(1.dp, colors.agent.copy(alpha = 0.35f), shape)
            else -> Modifier.background(colors.surface).border(colors.lineWidth, colors.stroke, shape)
        }
        Text(
            m.text,
            Modifier
                .fillMaxWidth(0.82f)
                .wrapContentWidth(if (m.mine) Alignment.End else Alignment.Start)
                .clip(shape)
                .then(fill)
                .padding(horizontal = 14.dp, vertical = 11.dp),
            color = if (m.mine) colors.onEmber else colors.ink,
            style = MaterialTheme.typography.bodyLarge,
        )
    }
}

/** 낮불 에이전트 말풍선의 파랑 점선(그라데이션·반투명 없이 색과 모양으로 구분). 선은 안쪽으로 그린다(앞의 clip 에 반이 잘리지 않게). */
private fun Modifier.dashedBorder(width: Dp, color: Color, shape: Shape): Modifier = drawBehind {
    val w = width.toPx()
    inset(w / 2f) {
        drawOutline(
            shape.createOutline(size, layoutDirection, this),
            color,
            style = Stroke(width = w, pathEffect = PathEffect.dashPathEffect(floatArrayOf(6.dp.toPx(), 4.dp.toPx()))),
        )
    }
}

/** status-v1(#560) 작업 상태 말풍선: 에이전트 색(파랑 stroke 35%·fill 10%, 낮불은 흰 면 + 파랑 실선)과 「· 불지기」 라벨로 일반 말풍선과 구분만 한다(오너 2026-10-30). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun StatusRow(s: StatusUi) {
    val colors = LocalHandeColors.current
    Row(Modifier.fillMaxWidth().padding(vertical = 3.dp), horizontalArrangement = Arrangement.Start) {
        OutlinedCard(
            border = BorderStroke(if (colors.isDay) colors.lineWidth else 1.dp, if (colors.isDay) colors.agent else colors.agent.copy(alpha = 0.35f)),
            colors = CardDefaults.outlinedCardColors(containerColor = if (colors.isDay) colors.surface else colors.agent.copy(alpha = 0.10f), contentColor = colors.ink),
        ) {
            Column(Modifier.padding(10.dp)) {
                Text("${AgentActors.displayName(s.sender)} · ${Strings.agentBadge}", style = MaterialTheme.typography.bodySmall, color = colors.agentText)
                Text(s.text)
            }
        }
        Spacer(Modifier.width(48.dp))
    }
}

/** 허브의 한 줄 알림(3초 뒤 지움). `SnackbarHostState` 큐 대신 상태 하나 — 알림은 최신 것 하나면 된다. */
@Composable
private fun NoticeHost(notice: String?, onShown: () -> Unit) {
    if (notice != null) {
        LaunchedEffect(notice) { delay(3_000); onShown() }
        Snackbar(Modifier.padding(12.dp)) { Text(notice) }
    }
}

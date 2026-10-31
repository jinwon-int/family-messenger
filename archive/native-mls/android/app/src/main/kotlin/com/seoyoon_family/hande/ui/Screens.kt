// 화면 3 + 1(#338 B1 골격): 처음 설정 · 등록 대기/세션 · 대화방 목록 · 대화. 꾸밈 없이 코어 동작을 눌러 볼 수 있는 최소 UI — C 단계가 다듬는다.
// #574 PR 4: 등록 대기의 형제 승인 모드(큰 지문·만료) · 목록 위의 「새 기기 승인」 카드 · 「내 기기」(registrar 부여/해제).
// #584 PR 3: 처음 설정의 서버 주소는 도메인만 — 「서버 찾기」(`.well-known/hande`) 가 서버 이름·주소를 보여 준 뒤 저장, 목록 제목 아래 서버 이름.
// #584 Play 출시: 「설정」(정보 · 개인정보처리방침 · 계정 및 데이터 삭제 링크 · 「이 기기 지우기」) — 등록 대기·로그인·목록·오류 화면 어디서나 연다(Play 정책: 앱 안 링크 + 앱 내 삭제 경로).
//   Android 16(targetSdk 36)은 edge-to-edge 강제(adjustResize 무효) → 입력 화면은 `imePadding`/`safeDrawingPadding`, 뒤로가기는 `BackHandler`(predictive back 기본 켜짐).
// 한데 디자인 1차(2026-10-31, docs/design/HANDE-DESIGN-SYSTEM.md): 토큰은 `ui/theme/HandeTheme.kt`(`LocalHandeColors`), 모닥불 배경 위에 투명 Scaffold/앱바 ·
//   목록 = 「자리」(불 세기 불꽃 · 좌석 점 · 안 읽음 주황 점; 「불지기」 배지는 오너 결정 #613/#540 으로 없음) · 대화 = 말풍선(면/불/파랑) + 알약 입력창 · 설정 「화면」(밤/낮불).
// 한데 디자인 2차-A(§A1~A6, iOS 전 화면의 M3 판 — 조각은 `ui/theme/HandeKit.kt`): 온보딩 4단계(진행 막대 · ① 서버 찾기 → ② 이름 → ③ 가족 로그인 → ④ 이 기기 등록) ·
//   새 기기 승인 전체 화면(`ApproveScreen`: 8행을 모두 눌러 표시해야 「승인」) · 목록 빈 상태 그림 · 꺼진 자리 안내 상자 · 설정 재배치(자주 → 드물게 → 위험).
//   Android 에 데이터가 없는 것(알림함·순서 편집·오프닝·로그아웃·서버 바꾸기·전송 상태·타닥타닥·폐기)은 그리지 않는다. 허브 호출·단계 매핑은 그대로.
// 한데 디자인 3차-A(Android Material 3 관용구): 투명 TopAppBar(64dp, 제목 왼쪽, 아이콘 버튼) · M3 OutlinedTextField(떠 있는 라벨 · isError + supportingText) · M3 Button/OutlinedButton/TextButton(알약) ·
//   목록 머리 = 큰 워드마크 + 설정 아이콘, ExtendedFloatingActionButton(56 · 반경 16) = 「참여 요청」(방 만들기가 없어 iOS 「불 피우기」의 Android 짝) · 설정 「화면」 = SingleChoiceSegmentedButtonRow ·
//   「이 기기 지우기」 확인 = AlertDialog(반경 28, surfaceContainerHigh) — 바텀시트 없음 · 등록되면 목록 + Snackbar 「등록됐어요 — 불 곁으로 오세요」 · 「등록 정보 공유」 = OutlinedButton + share ·
//   정책 링크 행은 open_in_new. 아이콘은 `ui/theme/HandeIcons.kt`(2차-B 아이콘 세트 + Material Symbols 짝 글리프, 라이브러리 의존 없음).
// 2차-B 낮불 세부: 꺼진 자리 = 흐림 대신 점선 1.5 회색 테두리 + 회색 글자 · 안 읽음 = 먹 알약 「새 글」 + 이름 800 · 승인 표시 = 먹 채움 + 종이 ✓ · 위험 구역 2px · 토스트 먹 면.
//   전송 상태(보내는 중·연결되면·전송 안 됨) 말풍선은 Android 화면 모델(`MessageUi`)에 상태가 없어 그리지 않는다.
package com.seoyoon_family.hande.ui

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
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
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedCard
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Snackbar
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
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
import androidx.compose.ui.graphics.drawOutline
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.inset
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.toggleableState
import androidx.compose.ui.state.ToggleableState
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.seoyoon_family.hande.BuildConfig
import com.seoyoon_family.hande.core.AgentActors
import com.seoyoon_family.hande.core.AgentChoices
import com.seoyoon_family.hande.core.AppLogin
import com.seoyoon_family.hande.core.CandidateUi
import com.seoyoon_family.hande.core.DeviceHub
import com.seoyoon_family.hande.core.FingerprintRows
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
import com.seoyoon_family.hande.ui.theme.Chevron
import com.seoyoon_family.hande.ui.theme.CreamButton
import com.seoyoon_family.hande.ui.theme.DangerButton
import com.seoyoon_family.hande.ui.theme.DetailDisclosure
import com.seoyoon_family.hande.ui.theme.DotsRow
import com.seoyoon_family.hande.ui.theme.EmptyCampfireArt
import com.seoyoon_family.hande.ui.theme.FieldLabel
import com.seoyoon_family.hande.ui.theme.FingerprintList
import com.seoyoon_family.hande.ui.theme.FlameIcon
import com.seoyoon_family.hande.ui.theme.HandeCard
import com.seoyoon_family.hande.ui.theme.HandeIcons
import com.seoyoon_family.hande.ui.theme.HandeOutlinedField
import com.seoyoon_family.hande.ui.theme.HandeSegmented
import com.seoyoon_family.hande.ui.theme.HandeToast
import com.seoyoon_family.hande.ui.theme.HandeWordmark
import com.seoyoon_family.hande.ui.theme.LinkButton
import com.seoyoon_family.hande.ui.theme.LocalHandeColors
import com.seoyoon_family.hande.ui.theme.LogIcon
import com.seoyoon_family.hande.ui.theme.OnboardingTitle
import com.seoyoon_family.hande.ui.theme.PrimaryButton
import com.seoyoon_family.hande.ui.theme.SeatDot
import com.seoyoon_family.hande.ui.theme.SecondaryButton
import com.seoyoon_family.hande.ui.theme.SectionCard
import com.seoyoon_family.hande.ui.theme.SectionHeader
import com.seoyoon_family.hande.ui.theme.SectionRow
import com.seoyoon_family.hande.ui.theme.StepBar
import com.seoyoon_family.hande.ui.theme.WarnBox
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 뿌리: 모닥불 배경(`CampfireBackground`) 위에 화면 하나. `themeMode`/`onThemeMode` 는 설정의 「화면」(밤/낮불) —
 * `MainActivity` 가 `HandeTheme` 모드를 바꾸고 `Settings.theme` 에 적는다(기본값은 다른 호출처가 그대로 컴파일되게 둔 것).
 * `approveId`(2차-A): 목록 카드의 「지문 비교」가 고른 후보 — 전체 화면 `ApproveScreen` 으로 연다(Ready 단계에서만).
 */
@Composable
fun HandeRoot(hub: DeviceHub, themeMode: HandeThemeMode = HandeThemeMode.NIGHT, onThemeMode: (HandeThemeMode) -> Unit = {}) {
    val ui by hub.ui.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    var openRoom by rememberSaveable { mutableStateOf<String?>(null) }

    var showDevices by rememberSaveable { mutableStateOf(false) }
    var showSettings by rememberSaveable { mutableStateOf(false) }
    var approveId by rememberSaveable { mutableStateOf<String?>(null) }
    val settingsOpen = showSettings && ui.phase !is Phase.Setup
    val approveTarget = approveId
    val approveOpen = !settingsOpen && approveTarget != null && ui.phase is Phase.Ready

    // 시스템 뒤로가기(predictive back 포함): 설정 → 승인 → 대화 → 내 기기 순으로 한 단계씩. 아무것도 열려 있지 않으면 기본 동작(앱 나가기).
    BackHandler(enabled = settingsOpen) { showSettings = false }
    BackHandler(enabled = approveOpen) { approveId = null }
    BackHandler(enabled = !settingsOpen && !approveOpen && openRoom != null) { openRoom = null }
    BackHandler(enabled = !settingsOpen && !approveOpen && openRoom == null && showDevices) { showDevices = false }

    // 「이 기기 지우기」: 설정 화면과 등록 대기(409 `device_exists`, #574 후속)의 버튼이 같은 동작 — 열린 화면을 닫고 허브가 지운 뒤 처음 설정으로.
    val wipe: () -> Unit = { showSettings = false; openRoom = null; showDevices = false; approveId = null; hub.wipeDevice(scope) }

    CampfireBackground {
        if (settingsOpen) {
            val onDevices: (() -> Unit)? = if (ui.phase is Phase.Ready) ({ showSettings = false; openRoom = null; showDevices = true }) else null
            SettingsScreen(
                ui, onBack = { showSettings = false }, onWipe = wipe, onNoticeShown = hub::clearNotice, themeMode = themeMode, onThemeMode = onThemeMode,
                relayHost = hub.settings.relayUrl?.substringAfter("://")?.substringBefore('/'), onDevices = onDevices,
            )
            return@CampfireBackground
        }
        if (approveOpen && approveTarget != null) {
            ApproveScreen(
                ui, deviceId = approveTarget, onApprove = { hub.approve(scope, it) }, onIgnore = { hub.dismissCandidate(scope, it) },
                onClose = { approveId = null }, onNoticeShown = hub::clearNotice,
            )
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
                    // 「내 기기」는 설정 → 기기 관리에서 연다(3차-A: 목록 오른쪽 위는 설정 아이콘 하나).
                    RoomListScreen(
                        ui, onOpen = { openRoom = it }, onRequestJoin = { hub.requestJoin(scope) },
                        onCompare = { approveId = it }, onIgnore = { hub.dismissCandidate(scope, it) },
                        onSettings = { showSettings = true }, onNoticeShown = hub::clearNotice,
                    )
                }
            }
        }
    }
}

/** 시각 한 줄(요청·만료 표시 — 시각만, 카운트다운 없음). */
private fun clock(ms: Long): String = SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(ms))

/** 릴레이 호스트(표시용): `https://relay.example/` → `relay.example`. */
private fun hostOf(url: String): String = url.substringAfter("://").substringBefore('/')

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

/** 「등록 정보 공유」: 시스템 공유 시트(ACTION_SEND, text/plain). 받을 앱이 없으면 `onFailed`(호출처가 클립보드로 대신한다). */
private fun shareText(context: Context, text: String, onFailed: () -> Unit) {
    val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text)
    try {
        context.startActivity(Intent.createChooser(send, null))
    } catch (_: ActivityNotFoundException) {
        onFailed()
    }
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

/** 앱바 왼쪽 아이콘 버튼(뒤로 arrow_back / 닫기 close) 48dp — 글리프는 `HandeIcons`(아이콘 라이브러리 의존 없음). */
@Composable
private fun BackButton(onClick: () -> Unit) {
    val colors = LocalHandeColors.current
    IconButton(onClick = onClick) { Icon(HandeIcons.back(colors.ink), contentDescription = Strings.back, tint = Color.Unspecified) }
}

@Composable
private fun CloseButton(onClick: () -> Unit) {
    val colors = LocalHandeColors.current
    IconButton(onClick = onClick) { Icon(HandeIcons.close(colors.ink), contentDescription = Strings.close, tint = Color.Unspecified) }
}

/**
 * 「이 기기 지우기」 확인 — 설정 화면과 등록 대기(ID 사용 불가)에서 같은 문구·같은 동작(#574 후속). 3차-A: 바텀시트 대신 M3 `AlertDialog`(안정 API) —
 * 반경 28(`shapes.extraLarge`) · 면 surfaceContainerHigh #1C2136(낮불 흰 면) · 제목 24/500 · 본문 15 · TextButton 「취소」/「지우기」(위험 쪽은 주의 글자색). 「지우기」가 기본 포커스를 받지 않는다.
 */
@Composable
private fun WipeConfirmDialog(onConfirm: () -> Unit, onDismiss: () -> Unit) {
    val colors = LocalHandeColors.current
    AlertDialog(
        onDismissRequest = onDismiss,
        shape = MaterialTheme.shapes.extraLarge,
        containerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
        titleContentColor = colors.ink,
        textContentColor = colors.inkDim,
        title = { Text(Strings.wipeDialogTitle, fontSize = 24.sp, lineHeight = 32.sp, fontWeight = FontWeight.Medium) },
        text = { Text(Strings.wipeDialogBody, fontSize = 15.sp, lineHeight = 23.sp) },
        confirmButton = {
            TextButton(onClick = onConfirm, colors = ButtonDefaults.textButtonColors(contentColor = colors.warnText)) { Text(Strings.wipeDialogConfirm) }
        },
        dismissButton = {
            TextButton(onClick = onDismiss, colors = ButtonDefaults.textButtonColors(contentColor = if (colors.isDay) colors.ink else colors.ember)) { Text(Strings.cancel) }
        },
    )
}

/** 허브의 한 줄 알림(3초 뒤 지움). `SnackbarHostState` 큐 대신 상태 하나 — 알림은 최신 것 하나면 된다. 모양은 2차-A 토스트(`HandeToast`). */
@Composable
private fun NoticeHost(notice: String?, onShown: () -> Unit) {
    if (notice != null) {
        LaunchedEffect(notice) { delay(3_000); onShown() }
        HandeToast(notice)
    }
}

// ---- 온보딩 4단계(2차-A §A2) ----

/**
 * 온보딩 화면 틀: 진행 막대(4칸) + (뒤로 / 오른쪽 위 링크) + (워드마크) + 제목 28/600 + 내용(스크롤) + 아래 버튼 칸(좌우 24·상하 12).
 * `safeDrawingPadding` 이 시스템 바·키보드를 모두 피한다(edge-to-edge). 알림은 맨 아래 토스트.
 */
@Composable
private fun OnboardingFrame(
    step: Int,
    title: String?,
    wordmark: Boolean = false,
    onBack: (() -> Unit)? = null,
    topEnd: (@Composable () -> Unit)? = null,
    notice: String? = null,
    onNoticeShown: () -> Unit = {},
    footer: @Composable ColumnScope.() -> Unit,
    content: @Composable ColumnScope.() -> Unit,
) {
    Box(Modifier.fillMaxSize().safeDrawingPadding()) {
        Column(Modifier.fillMaxSize()) {
            StepBar(step, modifier = Modifier.padding(horizontal = 24.dp, vertical = 10.dp))
            Column(
                Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()).padding(start = 24.dp, end = 24.dp, top = 18.dp, bottom = 16.dp),
                verticalArrangement = Arrangement.spacedBy(18.dp),
            ) {
                if (onBack != null || topEnd != null) {
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        if (onBack != null) LinkButton("‹ ${Strings.onboardingBack}", onClick = onBack)
                        Spacer(Modifier.weight(1f))
                        topEnd?.invoke()
                    }
                }
                if (wordmark) HandeWordmark()
                if (title != null) OnboardingTitle(title)
                content()
            }
            Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(10.dp), content = footer)
        }
        Box(Modifier.align(Alignment.BottomCenter)) { NoticeHost(notice, onNoticeShown) }
    }
}

/** 오류 카드(2차-A): 카드 자리에 warn 선 1.5 + 1줄. */
@Composable
private fun ErrorCard(text: String) {
    val colors = LocalHandeColors.current
    HandeCard(stroke = colors.warn, lineWidth = 1.5.dp) { Text(text, color = colors.ink, fontSize = 14.sp, lineHeight = 20.sp) }
}

/**
 * 처음 설정(#584 PR 3 → 2차-A ①②): ① 서버 찾기 — 「서버 찾기」가 `.well-known/hande` 로 릴레이를 찾아 이름·주소 카드를 보여 주고 버튼이 「이 서버로 계속」으로 바뀐다
 * (릴레이 주소를 그대로 적은 옛 길은 문서가 없을 때의 폴백으로 그대로). ② 이름 — 이미 정해진 기기(`settings.actor != null`)는 건너뛰고 바로 저장.
 * 운영자용 세션 값은 ③ 가족 로그인의 「직접 입력」으로 옮겼다(같은 `Settings.accessToken`). 정책 링크는 로그인 전에도 보인다(#584 Play).
 */
@Composable
fun SetupScreen(settings: Settings, onDiscover: suspend (String) -> ServerDiscovery.Result, onSaved: () -> Unit) {
    val colors = LocalHandeColors.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var step by rememberSaveable { mutableStateOf(1) }
    var server by rememberSaveable { mutableStateOf(settings.relayUrl ?: "") }
    var actor by rememberSaveable { mutableStateOf(settings.actor ?: "") }
    var error by remember { mutableStateOf<String?>(null) }
    var linkError by remember { mutableStateOf<String?>(null) }
    var actorInvalid by remember { mutableStateOf(false) }
    var searching by remember { mutableStateOf(false) }
    var found by remember { mutableStateOf<ServerDiscovery.Result.Found?>(null) }
    val needsActor = settings.actor == null

    fun save(f: ServerDiscovery.Result.Found) {
        settings.relayUrl = f.baseUrl
        settings.serverName = f.name
        if (settings.actor == null) settings.actor = actor.trim()
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

    fun confirmActor() {
        if (!Settings.validActor(actor.trim())) { actorInvalid = true; return }
        actorInvalid = false
        val f = found
        if (f != null) save(f) else discover { save(it) } // 회전 등으로 찾은 서버를 잃었으면 다시 찾고 저장
    }

    BackHandler(enabled = step == 2) { step = 1 }

    if (step == 1) {
        val f = found
        OnboardingFrame(
            step = 1, title = Strings.serverStepTitle, wordmark = true,
            notice = linkError, onNoticeShown = { linkError = null },
            footer = {
                if (f != null && error == null) {
                    PrimaryButton(Strings.serverContinue, enabled = !searching) { if (needsActor) step = 2 else save(f) }
                } else {
                    PrimaryButton(if (searching) Strings.findingServer else Strings.findServer, enabled = !searching && server.isNotBlank()) { discover() }
                }
            },
        ) {
            // #584 PR 4(가이드라인 4.2 대비): 서버 주소가 없어도 앱이 무엇인지 알 수 있는 선언 — 첫 화면 맨 위 카드.
            HandeCard(fill = colors.ember.copy(alpha = 0.08f), stroke = colors.ember.copy(alpha = 0.35f)) {
                Text(Strings.serverDeclaration, color = colors.ink, fontSize = 16.sp, lineHeight = 24.sp, fontWeight = FontWeight.Medium)
            }
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                // 3차-A: M3 OutlinedTextField — 라벨이 선 위에 뜨고, 찾기 실패는 isError + supportingText(오류 카드 대신).
                HandeOutlinedField(
                    server, { server = it; found = null; error = null }, label = Strings.serverAddressLabel, placeholder = Strings.serverAddressPlaceholder, mono = true,
                    error = error, enabled = !searching, keyboardType = KeyboardType.Uri, onDone = { discover() },
                )
                DetailDisclosure(hint = Strings.serverAddressHint, detail = Strings.serverAddressDetail)
                // 로그인 전에도 보이는 정책 링크(#584 Play: 개인정보처리방침은 앱 안에서 열려야 한다). 삭제 안내는 설정 화면에도 있다.
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    LinkButton(Strings.privacyPolicy, size = 13.sp) { openPolicy(context, BuildConfig.PRIVACY_URL) { linkError = Strings.openLinkFailed } }
                    LinkButton(Strings.deleteAccount, size = 13.sp) { openPolicy(context, BuildConfig.DELETE_ACCOUNT_URL) { linkError = Strings.openLinkFailed } }
                }
            }
            if (f != null && error == null) {
                HandeCard {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
                            SeatDot(agent = false); SeatDot(agent = false); SeatDot(agent = true)
                        }
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                            Text(f.name ?: Strings.serverUnnamed, color = colors.ink, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
                            Text(hostOf(f.baseUrl), color = colors.inkDim, fontSize = 13.sp, fontFamily = FontFamily.Monospace, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                        Text(Strings.serverFound, color = colors.inkDim, fontSize = 13.sp)
                    }
                    if (f.wellKnown == null) Text(Strings.serverDirect, Modifier.padding(top = 8.dp), color = colors.inkDim, fontSize = 13.sp)
                    if (!f.healthOk) Text(Strings.serverGated, Modifier.padding(top = 4.dp), color = colors.inkDim, fontSize = 13.sp)
                }
            }
        }
    } else {
        OnboardingFrame(
            step = 2, title = Strings.actorStepTitle, onBack = { step = 1 },
            footer = { PrimaryButton(Strings.save, enabled = !searching && actor.isNotBlank()) { confirmActor() } },
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                // 형식 오류는 isError + supportingText 주의 글자색(판정은 `Settings.validActor` 그대로).
                HandeOutlinedField(
                    actor, { actor = it.lowercase(); actorInvalid = false }, label = Strings.actorStepLabel, placeholder = Strings.actorStepPlaceholder, mono = true,
                    error = if (actorInvalid) Strings.actorStepInvalid else null, enabled = !searching, keyboardType = KeyboardType.Ascii, onDone = { confirmActor() },
                )
                DetailDisclosure(hint = Strings.actorStepHint, detail = Strings.actorStepDetail)
            }
            error?.let { ErrorCard(it) }
        }
    }
}

/**
 * 가족 로그인(B2 → 2차-A ③, iOS LoginView 와 같은 구성): 1줄 + 「자세히」 + 크림 면 「Google 계정으로 로그인」(화면의 할 일이 하나).
 * 운영자용 세션 값 붙여넣기는 맨 아래 접힌 행 「직접 입력(운영자용)」 — 숨기지 않되 가족 눈에 덜 띄게. 저장은 그대로 `Settings.accessToken` → `onSaved`.
 */
@Composable
fun LoginScreen(settings: Settings, ui: HubUi, onGoogle: () -> Unit, onSaved: () -> Unit, onSettings: () -> Unit, onNoticeShown: () -> Unit) {
    val colors = LocalHandeColors.current
    var token by rememberSaveable { mutableStateOf("") }
    var manualExpanded by rememberSaveable { mutableStateOf(false) }
    fun connect() {
        if (token.isBlank()) return
        settings.accessToken = token
        token = ""
        onSaved()
    }
    OnboardingFrame(
        step = 3, title = Strings.loginTitle, topEnd = { LinkButton(Strings.settingsButton, onClick = onSettings) },
        notice = ui.notice, onNoticeShown = onNoticeShown,
        footer = {
            HandeCard(padding = 0.dp) {
                SectionRow(divider = false, onClick = { manualExpanded = !manualExpanded }) {
                    Text(Strings.loginManualTitle, Modifier.weight(1f), color = colors.inkDim, fontSize = 15.sp)
                    Chevron(down = manualExpanded)
                }
                if (manualExpanded) {
                    Column(Modifier.padding(start = 16.dp, end = 16.dp, bottom = 16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        HandeOutlinedField(token, { token = it }, label = Strings.loginField, mono = true, secure = true, onDone = { connect() })
                        SecondaryButton(Strings.loginButton, enabled = token.isNotBlank()) { connect() }
                        Text(Strings.loginManualHint, color = colors.inkDim, fontSize = 13.sp, lineHeight = 18.sp)
                    }
                }
            }
        },
    ) {
        DetailDisclosure(hint = Strings.loginStepLine, detail = Strings.loginStepDetail, hintSize = 16.sp)
        CreamButton(Strings.loginGoogle, Modifier.padding(top = 8.dp), enabled = settings.relayUrl != null) { onGoogle() }
    }
}

/**
 * 이 기기 등록(#574 → 2차-A ④): 1줄 + 「자세히」(모드별 긴 안내) + 지문 1열 8행(승인 화면과 같은 행·번호) + 기기 ID 모노 +
 * 「운영자 승인을 기다리는 중」/「다른 기기의 승인을 기다리는 중 · HH:mm까지」(점 3개 고정, 만료는 시각만) + 「등록 정보 공유」(시스템 공유; 못 열면 클립보드) + 「등록 확인」.
 * 운영자 JSON 은 「운영자 등록 정보 보기」로 접어 둔다(복사 버튼 포함). 옛 문구의 기술값 「(403 device_subject_mismatch)」는 화면에서 뺐다.
 * ID_TAKEN(409 `device_exists`, #574 후속)에는 「이 기기 지우기 / 새 ID로 다시 시작」 — 설정 화면의 「이 기기 지우기」와 같은 확인 대화상자·같은 동작(`onWipe`).
 */
@Composable
fun EnrollScreen(ui: HubUi, phase: Phase.WaitingEnrollment, onSettings: () -> Unit, onWipe: () -> Unit, onRetry: () -> Unit) {
    val colors = LocalHandeColors.current
    val context = LocalContext.current
    val clipboard = LocalClipboardManager.current
    var toast by remember { mutableStateOf<String?>(null) }
    var operatorShown by rememberSaveable { mutableStateOf(false) }
    var confirmWipe by rememberSaveable { mutableStateOf(false) }
    val mode = phase.mode
    val json = phase.json
    val detail = when (mode) {
        SelfService.EnrollMode.SIBLING -> Strings.enrollSiblingBody
        SelfService.EnrollMode.ID_TAKEN -> Strings.enrollIdTaken
        SelfService.EnrollMode.OPERATOR -> "${Strings.enrollBody} ${Strings.enrollOperatorOnly}"
    }
    val status = when (mode) {
        SelfService.EnrollMode.SIBLING -> phase.expiresAt?.let { Strings.enrollWaitingSiblingUntil(clock(it)) } ?: Strings.enrollWaitingSibling
        SelfService.EnrollMode.ID_TAKEN, SelfService.EnrollMode.OPERATOR -> Strings.enrollWaitingOperator
    }
    val rows = remember(ui.fingerprint) { FingerprintRows.make(ui.fingerprint ?: "") }
    fun copyJson() { clipboard.setText(AnnotatedString(json)); toast = Strings.copiedToast }

    OnboardingFrame(
        step = 4, title = Strings.enrollTitle, topEnd = { LinkButton(Strings.settingsButton, onClick = onSettings) },
        notice = toast, onNoticeShown = { toast = null },
        footer = {
            if (mode != SelfService.EnrollMode.ID_TAKEN && json.isNotEmpty()) {
                // 3차-A: OutlinedButton + share 아이콘 → 시스템 공유 시트.
                SecondaryButton(
                    Strings.shareRegistration,
                    icon = { Icon(HandeIcons.share(colors.ink), contentDescription = null, Modifier.size(20.dp), tint = Color.Unspecified) },
                ) { shareText(context, json) { copyJson() } }
            }
            LinkButton(Strings.enrolledButton, Modifier.align(Alignment.CenterHorizontally), onClick = onRetry)
        },
    ) {
        DetailDisclosure(hint = Strings.enrollStepLine, detail = detail, hintSize = 15.sp)
        if (mode == SelfService.EnrollMode.ID_TAKEN) {
            ErrorCard(Strings.enrollIdTaken)
            DangerButton(Strings.wipeAndRestart) { confirmWipe = true }
        } else {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                FieldLabel(Strings.fingerprintLabel)
                FingerprintList(rows)
            }
            Row(Modifier.padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                DotsRow(colors.person)
                Text(status, color = colors.ink, fontSize = 15.sp)
            }
        }
        Text("${Strings.deviceIdLabel} ${ui.deviceId ?: ""}", Modifier.padding(horizontal = 4.dp), color = colors.inkDim, fontSize = 13.sp, fontFamily = FontFamily.Monospace)
        // 운영자 CLI(`-add-device`)에 줄 등록 JSON — 접어 두되 숨기지 않는다.
        LinkButton(if (operatorShown) Strings.hideOperatorInfo else Strings.showOperatorInfo) { operatorShown = !operatorShown }
        if (operatorShown) {
            HandeCard(padding = 12.dp) { Text(json, color = colors.ink, fontSize = 12.sp, lineHeight = 17.sp, fontFamily = FontFamily.Monospace) }
            SecondaryButton(Strings.copyRegistration, height = 44.dp) { copyJson() }
        }
    }
    if (confirmWipe) WipeConfirmDialog(onConfirm = { confirmWipe = false; onWipe() }, onDismiss = { confirmWipe = false })
}

// ---- 새 기기 승인(2차-A §A1) ----

/** 후보 기기 정보(목록 카드·승인 화면 공용): 15 보조 + ID 모노 18 + 「요청 HH:mm · HH:mm에 만료」 14(아는 시각만). */
@Composable
private fun CandidateInfo(c: CandidateUi) {
    val colors = LocalHandeColors.current
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(Strings.candidateIncoming, color = colors.inkDim, fontSize = 15.sp)
        Text(c.deviceId, color = colors.ink, fontSize = 18.sp, fontFamily = FontFamily.Monospace, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Strings.candidateTimes(c.createdAt?.let(::clock), c.expiresAt?.let(::clock))?.let { Text(it, color = colors.inkDim, fontSize = 14.sp) }
    }
}

/** 목록 위의 새 기기 승인 카드(#574 → 2차-A): 정보 + 「지문 비교」(주, 전체 화면으로) / 「무시」(보조 — 프로세스가 다시 떠도 숨김, 후보 TTL 뒤 만료). 실패 사유는 카드 안에. */
@Composable
private fun CandidateCard(c: CandidateUi, onCompare: () -> Unit, onIgnore: () -> Unit) {
    val colors = LocalHandeColors.current
    HandeCard {
        CandidateInfo(c)
        c.message?.let { Text(it, Modifier.padding(top = 6.dp), color = colors.warn, fontSize = 14.sp) }
        Row(Modifier.padding(top = 10.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            PrimaryButton(Strings.candidateCompareButton, Modifier.weight(1f), enabled = !c.busy, height = 44.dp, disabledText = Strings.approving, onClick = onCompare)
            SecondaryButton(Strings.ignoreButton, Modifier.weight(1f), enabled = !c.busy, height = 44.dp, onClick = onIgnore)
        }
    }
}

/**
 * 지문 비교 → 승인, 전체 화면(iOS CandidateApprovalView · 웹 approve 시트 relay 모드). 「대충 승인」을 막는 세 겹(§A1):
 * 등록 화면과 같은 1열·같은 번호, 행마다 직접 눌러 표시(8행 전부 표시 전엔 「승인」 꺼짐 — 「8줄을 모두 맞춰 보세요」), 「지문이 다르면…」 경고 + 같은 높이의 「다릅니다」.
 * 승인은 기존 `DeviceHub.approve`(코어가 지문을 다시 계산해 다르면 거부). 결과 판정: 누른 뒤 후보가 목록에서 사라지면 승인됨(허브가 승인 뒤 제거),
 * 바쁨이 끝났는데 남아 있으면 실패(사유는 `message`). 「다릅니다」 = 후보를 무시(`dismissCandidate`) + 「승인하지 않았어요」 + 진단 기록 복사.
 * 표시 상태는 회전하면 비워진다(`remember`) — 다시 맞춰 보게 하는 쪽이 안전하다.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ApproveScreen(ui: HubUi, deviceId: String, onApprove: (String) -> Unit, onIgnore: (String) -> Unit, onClose: () -> Unit, onNoticeShown: () -> Unit) {
    val colors = LocalHandeColors.current
    val clipboard = LocalClipboardManager.current
    val candidate = ui.candidates.firstOrNull { it.deviceId == deviceId }
    val first = remember { candidate }
    val info = candidate ?: first
    var ticked by remember { mutableStateOf(emptySet<Int>()) }
    var submitted by remember { mutableStateOf(false) }
    var sawBusy by remember { mutableStateOf(false) }
    var outcome by rememberSaveable { mutableStateOf<String?>(null) } // "approved" | "rejected"
    var toast by remember { mutableStateOf<String?>(null) }
    val rows = remember(info?.fingerprint) { FingerprintRows.make(info?.fingerprint ?: "") }
    val allTicked = rows.isNotEmpty() && ticked.size == rows.size
    val busy = candidate?.busy == true

    LaunchedEffect(candidate, submitted) {
        if (outcome != null) return@LaunchedEffect
        if (!submitted) {
            if (candidate == null) onClose() // 만료·다른 기기의 승인 등으로 사라졌다 — 비교할 것이 없다
            return@LaunchedEffect
        }
        when {
            candidate == null -> outcome = "approved"
            candidate.busy -> sawBusy = true
            sawBusy -> { submitted = false; sawBusy = false } // 바쁨이 끝났는데 남아 있다 = 실패(사유는 카드의 message)
        }
    }

    fun diagnostics(): String = buildString {
        appendLine("hande new-device candidate — rejected by user (fingerprint mismatch)")
        appendLine("candidate: ${info?.deviceId ?: deviceId}")
        appendLine("actor: ${info?.actor ?: "?"}")
        appendLine("fingerprint: ${info?.fingerprint ?: "?"}")
        appendLine("created_at: ${info?.createdAt?.let(::clock) ?: "?"} · expires_at: ${info?.expiresAt?.let(::clock) ?: "?"}")
        appendLine("last_message: ${info?.message ?: "-"}")
        appendLine("this_device: ${ui.deviceId ?: "?"} · server: ${ui.server ?: "?"}")
    }

    Scaffold(
        containerColor = Color.Transparent, contentColor = MaterialTheme.colorScheme.onBackground,
        topBar = {
            HandeTopBar(title = { Text(Strings.candidatesTitle) }, navigationIcon = { CloseButton(onClose) })
        },
        snackbarHost = { NoticeHost(ui.notice ?: toast) { toast = null; onNoticeShown() } },
    ) { pad ->
        when (outcome) {
            "approved" -> ResultColumn(pad, footer = { PrimaryButton(Strings.approveConfirmButton, onClick = onClose) }) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) { SeatDot(agent = false, size = 12.dp); SeatDot(agent = false, size = 12.dp); SeatDot(agent = false, size = 12.dp) }
                Text(Strings.approvedTitle(deviceId), color = colors.ink, fontSize = 22.sp, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center)
                Text(Strings.approvedBody, color = colors.inkDim, fontSize = 16.sp, lineHeight = 24.sp, textAlign = TextAlign.Center)
            }
            "rejected" -> ResultColumn(pad, footer = {
                SecondaryButton(Strings.copyDiagnosticsButton) { clipboard.setText(AnnotatedString(diagnostics())); toast = Strings.copiedToast }
                PrimaryButton(Strings.close, onClick = onClose)
            }) {
                Box(Modifier.size(12.dp).clip(CircleShape).background(colors.ash))
                Text(Strings.rejectedTitle, color = colors.ink, fontSize = 22.sp, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center)
                Text(Strings.rejectedBody(deviceId), color = colors.inkDim, fontSize = 16.sp, lineHeight = 24.sp, textAlign = TextAlign.Center)
            }
            else -> Column(Modifier.padding(pad).fillMaxSize()) {
                Column(
                    Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()).padding(start = 16.dp, end = 16.dp, top = 6.dp, bottom = 12.dp),
                    verticalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    if (info != null) HandeCard { CandidateInfo(info) }
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(Strings.approveCompareTitle, Modifier.padding(horizontal = 4.dp), color = colors.ink, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                        FingerprintList(rows, ticked = ticked, enabled = !busy) { i -> ticked = if (i in ticked) ticked - i else ticked + i }
                        Text(
                            if (allTicked) Strings.approveAllMatched else Strings.approveProgress(ticked.size, rows.size),
                            Modifier.padding(horizontal = 4.dp), color = colors.inkDim, fontSize = 14.sp,
                        )
                    }
                    WarnBox(Strings.approveWarning)
                    candidate?.message?.let { Text(it, Modifier.padding(horizontal = 4.dp), color = colors.warn, fontSize = 14.sp) }
                }
                Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    val gateLabel = Strings.approveDisabledAccessibility(rows.size)
                    PrimaryButton(
                        Strings.approveConfirm,
                        if (allTicked) Modifier else Modifier.semantics { contentDescription = gateLabel },
                        enabled = allTicked && !busy && rows.isNotEmpty(),
                        disabledText = if (busy) Strings.approving else Strings.approveDisabled(rows.size),
                    ) { submitted = true; sawBusy = false; onApprove(deviceId) }
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        DangerButton(Strings.approveMismatchButton, Modifier.weight(1f), enabled = !busy) { outcome = "rejected"; onIgnore(deviceId) }
                        SecondaryButton(Strings.approveLaterButton, Modifier.weight(1f), enabled = !busy, height = 46.dp, onClick = onClose)
                    }
                }
            }
        }
    }
}

/** 결과 화면 틀(승인했어요 / 승인하지 않았어요): 가운데 글자(성공 표시는 글자로만, 체크 배지 없음) + 아래 버튼. */
@Composable
private fun ResultColumn(pad: PaddingValues, footer: @Composable ColumnScope.() -> Unit, content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.padding(pad).fillMaxSize()) {
        Column(
            Modifier.weight(1f).fillMaxWidth().padding(horizontal = 32.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp, Alignment.CenterVertically), horizontalAlignment = Alignment.CenterHorizontally,
            content = content,
        )
        Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(10.dp), content = footer)
    }
}

/** 작은 표지(이 기기 · 등록 기기 · 폐기). */
@Composable
private fun Pill(text: String, color: Color, fill: Color) {
    Text(text, Modifier.clip(CircleShape).background(fill).padding(horizontal = 8.dp, vertical = 3.dp), color = color, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
}

/** 「내 기기」(#574 E5): 체인의 내 기기 전부(이 기기 먼저) — 상태·등록 기기 표시·지문, 허용될 때만 부여/해제 링크. 폐기(revoke)는 Android 에 API 가 없어 없다. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DevicesScreen(ui: HubUi, onBack: () -> Unit, onGrant: (String) -> Unit, onRelease: (String) -> Unit, onNoticeShown: () -> Unit) {
    val colors = LocalHandeColors.current
    Scaffold(
        containerColor = Color.Transparent, contentColor = MaterialTheme.colorScheme.onBackground,
        topBar = { HandeTopBar(title = { Text(Strings.devicesTitle) }, navigationIcon = { BackButton(onBack) }) },
        snackbarHost = { NoticeHost(ui.notice, onNoticeShown) },
    ) { pad ->
        val view = ui.devices
        Column(Modifier.padding(pad).fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (view == null || view.devices.isEmpty()) {
                HandeCard { Text(Strings.devicesEmpty, color = colors.inkDim, fontSize = 14.sp) }
            } else {
                for (d in view.devices) {
                    val active = d.status == SelfService.STATUS_ACTIVE
                    HandeCard(Modifier.alpha(if (active) 1f else 0.55f)) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            Text(d.deviceId, Modifier.weight(1f, fill = false), color = colors.ink, fontSize = 15.sp, fontFamily = FontFamily.Monospace, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            if (d.isSelf) Pill(Strings.thisDevice, colors.inkDim, colors.surface)
                            if (d.registrar) Pill(Strings.registrarPill, colors.ember, colors.ember.copy(alpha = 0.16f))
                            if (!active) Pill(Strings.statusRevoked, colors.inkDim, colors.ash.copy(alpha = 0.35f))
                        }
                        Text(
                            if (active) Strings.statusActive else "${Strings.statusRevoked} · ${d.status}",
                            Modifier.padding(top = 4.dp), color = if (active) colors.inkDim else colors.warn, fontSize = 13.sp,
                        )
                        Text(SelfService.groupedFingerprint(d.fingerprint), Modifier.padding(top = 4.dp), color = colors.inkDim, fontSize = 12.sp, fontFamily = FontFamily.Monospace)
                        when {
                            d.grant -> LinkButton(Strings.grantButton) { onGrant(d.deviceId) }
                            d.release -> LinkButton(Strings.releaseButton) { onRelease(d.deviceId) }
                            d.lastRegistrar -> Text(Strings.lastRegistrarNote, Modifier.padding(top = 6.dp), color = colors.inkDim, fontSize = 13.sp)
                        }
                    }
                }
            }
            Text(Strings.devicesHint, Modifier.padding(horizontal = 4.dp), color = colors.inkDim, fontSize = 13.sp, lineHeight = 18.sp)
        }
    }
}

// ---- 대화 목록 · 대화방 ----

/**
 * 대화 목록 = 「자리」(3차-A A2): 머리는 TopAppBar 대신 큰 워드마크(34) + 「오늘 밤, 모닥불에 한데 모여」 + 서버 이름(#584), 오른쪽 위는 설정 아이콘 하나
 * (초대 벨·순서 편집은 Android 에 그 데이터가 없다; 「내 기기」는 설정 → 기기 관리). 낮불은 머리 아래 먹 선 1.5(2차-B). 방 행 카드(`RoomRow`).
 * `ExtendedFloatingActionButton`(56 · 반경 16 · 오른쪽 아래 16dp · 불 면) — iOS 「불 피우기」의 Android 짝이지만 Android 에는 방 만들기가 없어 기존 동작 「참여 요청」(로비 키 게시)을 단다(의도된 차이).
 * 빈 상태(2차-A §A3): 꺼진 장작 그림(불 그림은 여기만) + 「아직 피운 모닥불이 없습니다」 + 1줄.
 * 등록 직후(허브가 WaitingEnrollment → Ready 전환에 `enrolledNow` 알림을 싣는다)는 토스트 대신 M3 Snackbar 「등록됐어요 — 불 곁으로 오세요」.
 * 기기 ID·로비 키·키 보관은 설정 → 이 기기 → 운영자용 정보로 옮겼다(목록 아래 줄 없음).
 */
@Composable
fun RoomListScreen(
    ui: HubUi, onOpen: (String) -> Unit, onRequestJoin: () -> Unit,
    onCompare: (String) -> Unit, onIgnore: (String) -> Unit, onSettings: () -> Unit, onNoticeShown: () -> Unit,
) {
    val colors = LocalHandeColors.current
    val snackbar = remember { SnackbarHostState() }
    val enrolled = ui.notice == Strings.enrolledNow
    LaunchedEffect(enrolled) {
        if (enrolled) {
            snackbar.showSnackbar(Strings.enrolledSnackbar, duration = SnackbarDuration.Short)
            onNoticeShown()
        }
    }
    Scaffold(
        containerColor = Color.Transparent, contentColor = MaterialTheme.colorScheme.onBackground,
        snackbarHost = {
            Column {
                NoticeHost(if (enrolled) null else ui.notice, onNoticeShown)
                SnackbarHost(snackbar) { data ->
                    Snackbar(
                        data, shape = RoundedCornerShape(20.dp),
                        containerColor = if (colors.isDay) colors.ink else MaterialTheme.colorScheme.surfaceContainerHigh,
                        contentColor = if (colors.isDay) colors.bgTop else colors.ink,
                    )
                }
            }
        },
        floatingActionButton = {
            ExtendedFloatingActionButton(
                text = { Text(Strings.requestJoin, fontSize = 16.sp, fontWeight = FontWeight.SemiBold) },
                icon = { Icon(HandeIcons.add(colors.onEmber), contentDescription = null, tint = Color.Unspecified) },
                onClick = onRequestJoin,
                shape = RoundedCornerShape(16.dp),
                containerColor = colors.ember,
                contentColor = colors.onEmber,
            )
        },
    ) { pad ->
        Column(Modifier.padding(pad).fillMaxSize()) {
            Row(Modifier.fillMaxWidth().padding(start = 20.dp, end = 8.dp, top = 16.dp, bottom = 10.dp), verticalAlignment = Alignment.Bottom) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    HandeWordmark(size = 34.sp)
                    // 연결 중이면 부제 자리에 그 사실을.
                    Text(if (ui.connecting) Strings.connecting else Strings.campfireSubtitle, color = colors.inkDim, fontSize = 15.sp)
                    // 워드마크 아래 서버 이름(#584): `.well-known` 의 이름, 없으면 릴레이 호스트 — 다른 운영자의 서버에 붙었을 때 어디인지 보인다.
                    ui.server?.let { Text(it, style = MaterialTheme.typography.labelSmall, color = colors.inkDim, maxLines = 1, overflow = TextOverflow.Ellipsis) }
                }
                IconButton(onClick = onSettings) { Icon(HandeIcons.settings(colors.ink), contentDescription = Strings.settingsButton, tint = Color.Unspecified) }
            }
            if (colors.isDay) HorizontalDivider(thickness = 1.5.dp, color = colors.ink)
            // 새 기기 승인 요청(#574): 등록 기기(또는 registrar 없는 actor 의 활성 기기)에게만 보인다. 「지문 비교」→ 전체 화면 `ApproveScreen`.
            if (ui.candidates.isNotEmpty()) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(Strings.candidatesTitle, style = MaterialTheme.typography.titleMedium)
                    for (c in ui.candidates) CandidateCard(c, onCompare = { onCompare(c.deviceId) }, onIgnore = { onIgnore(c.deviceId) })
                }
                HorizontalDivider(color = colors.stroke)
            }
            if (ui.rooms.isEmpty()) {
                Column(
                    Modifier.weight(1f).fillMaxWidth().padding(horizontal = 40.dp),
                    verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically), horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    EmptyCampfireArt()
                    Text(Strings.campfireEmpty, color = colors.ink, fontSize = 20.sp, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center)
                    Text(Strings.emptyRoomsHint, color = colors.inkDim, fontSize = 15.sp, lineHeight = 22.sp, textAlign = TextAlign.Center)
                }
            } else {
                // 아래 여백 88 = FAB 56 + 16 + 16 — 마지막 행이 FAB 에 가리지 않게.
                LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(top = 6.dp, bottom = 88.dp)) {
                    items(ui.rooms, key = { it.room }) { r -> RoomRow(r) { onOpen(r.room) } }
                }
            }
        }
    }
}

/**
 * 방 행 카드: 원형 아이콘(불 세기 1~3단 불꽃 / 꺼진 자리는 장작) · 이름 · 미리보기 · 좌석 점 · 안 읽음 주황 점(개수 없음).
 * 「불지기」 배지는 목록에 넣지 않는다(오너 2026-10-31 iOS #613 · 웹 #540 — 디자인 1차 1b 보다 이 결정이 우선). 에이전트는 좌석 점의 파란 점으로 보인다.
 * 「오늘의 불 세기」는 시각이 화면 모델에 없어(`MessageUi` 에 received_at 없음) 보관된 글 수로 가늠한다 — 12건 이상 3단 · 3건 이상 2단 · 그 밖 1단. 숫자는 보이지 않는다.
 * 꺼진 자리 = 60% 흐림 + 장작 + 「불이 꺼진 자리 · 운영자가 닫음」(`room_closed` 일 때만 — 다른 정지 사유는 토큰을 그대로 적는다).
 * 낮불(2차-B): 흐림(투명도) 금지 → 점선 1.5 회색 #8A8178 테두리 + 회색 글자 + 장작 · 아이콘 원은 면 대신 먹 선 1.5 · 안 읽음은 주황 점 대신 먹 알약 「새 글」 + 이름 800(작은 점은 e-ink 잔상에 묻힌다).
 */
@Composable
private fun RoomRow(r: RoomUi, onOpen: () -> Unit) {
    val colors = LocalHandeColors.current
    val day = colors.isDay
    val halted = r.halted != null
    val closedDay = halted && day
    val shape = RoundedCornerShape(16.dp)
    val level = when {
        r.messages.size >= 12 -> 3
        r.messages.size >= 3 -> 2
        else -> 1
    }
    val textColor = if (closedDay) colors.ash else colors.ink
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 5.dp)
            .alpha(if (halted && !day) 0.6f else 1f)
            .clip(shape)
            .background(colors.surface)
            .then(if (closedDay) Modifier.dashedBorder(1.5.dp, colors.ash, shape) else Modifier.border(colors.lineWidth, colors.stroke, shape))
            .clickable(onClick = onOpen)
            .padding(horizontal = 14.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        val ring = if (day) {
            Modifier.border(1.5.dp, if (halted) colors.ash else colors.ink, CircleShape)
        } else {
            Modifier.background(colors.ember.copy(alpha = if (halted) 0.06f else 0.12f))
        }
        Box(Modifier.size(48.dp).clip(CircleShape).then(ring), contentAlignment = Alignment.Center) {
            if (halted) LogIcon() else FlameIcon(level, dim = false, contentDescription = Strings.fireLevel(level))
        }
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text(
                r.room, color = textColor, fontSize = 17.sp, lineHeight = 22.sp,
                fontWeight = if (day && r.unread) FontWeight.ExtraBold else FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
            Spacer(Modifier.height(3.dp))
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
                preview, fontSize = 15.sp, lineHeight = 20.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                color = when {
                    workingShown -> colors.ember
                    closedDay -> colors.ash
                    else -> colors.inkDim
                },
                fontWeight = if (workingShown) FontWeight.SemiBold else FontWeight.Normal,
            )
            SeatDots(r.messages)
        }
        // 안 읽음(#571 후속): 밤 = 주황 점 하나 + 빛남(개수 없음 — 글자는 접근성 문구로만) · 낮불 = 먹 알약 「새 글」(20dp · 반경 10 · 종이 12 굵게).
        // 같은 사람의 다른 기기(PC 웹·iPhone)에서 읽으면 다음 poll 에 꺼진다.
        if (r.unread) {
            Spacer(Modifier.width(8.dp))
            if (day) {
                Box(
                    Modifier.height(20.dp).clip(RoundedCornerShape(10.dp)).background(colors.ink).padding(horizontal = 7.dp),
                    contentAlignment = Alignment.Center,
                ) { Text(Strings.newPostPill, color = colors.bgTop, fontSize = 12.sp, fontWeight = FontWeight.Bold) }
            } else {
                Box(
                    Modifier
                        .size(10.dp)
                        .drawBehind { drawCircle(colors.ember.copy(alpha = 0.35f), radius = size.minDimension * 0.9f) }
                        .clip(CircleShape)
                        .background(colors.ember)
                        .semantics { contentDescription = Strings.unread },
                )
            }
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

/**
 * 대화방(한데 디자인 1차): 말풍선(`MessageRow`) · 작업 상태(`StatusRow`) · 알약 입력창 + 주황 보내기 원(`Composer`).
 * 꺼진 자리(2차-A §A6): 제목 아래 「불이 꺼진 자리」, 지난 말풍선 60%, 입력창 자리를 안내 상자(`HaltedBox`)로 교체 — 「덮어 두기」(보관)는 Android 에 없어 두지 않는다.
 */
@Composable
fun RoomScreen(room: RoomUi, ui: HubUi, onBack: () -> Unit, onSend: (String) -> Unit, onNoticeShown: () -> Unit) {
    val colors = LocalHandeColors.current
    var draft by rememberSaveable(room.room) { mutableStateOf("") }
    val listState = rememberLazyListState()
    val halted = room.halted
    // 맨 아래 따라가기: 새 글이나 작업 상태 말풍선이 생기면(사라질 때는 아님) 마지막 항목으로.
    val total = room.messages.size + room.statuses.size
    LaunchedEffect(room.messages.size, room.statuses.size) { if (total > 0) listState.animateScrollToItem(total - 1) }
    // agent-choices-v1(#620): 에이전트 글 끝 번호 선택지 → 말풍선 아래 카드(open/answered). 상태는 타임라인에서 계산(저장 안 함).
    val choiceCards = remember(room.messages) { AgentChoices.cards(room.messages) }
    val canChoose = halted == null && room.joined
    Scaffold(
        containerColor = Color.Transparent, contentColor = MaterialTheme.colorScheme.onBackground,
        topBar = {
            HandeTopBar(
                title = {
                    Column {
                        Text(if (ui.connecting) Strings.connecting else room.room, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        if (halted != null) Text(Strings.halted, color = colors.inkDim, fontSize = 12.sp)
                    }
                },
                navigationIcon = { BackButton(onBack) },
            )
        },
        snackbarHost = { NoticeHost(ui.notice, onNoticeShown) },
    ) { pad ->
        Column(Modifier.padding(pad).fillMaxSize().imePadding()) {
            LazyColumn(Modifier.weight(1f).fillMaxWidth().alpha(if (halted != null) 0.6f else 1f), state = listState, contentPadding = PaddingValues(12.dp)) {
                itemsIndexed(room.messages, key = { _, m -> "${m.sender}-${m.seq}" }) { i, m ->
                    val card = choiceCards.getOrNull(i)
                    if (card == null) {
                        MessageRow(m)
                    } else {
                        Column(Modifier.fillMaxWidth()) {
                            MessageRow(m)
                            AgentChoicesCard(m, card, enabled = canChoose, onSend = onSend)
                        }
                    }
                }
                // status-v1(#560): 보낸이별 임시 말풍선 하나 — 키가 보낸이라 제자리에서 본문만 바뀐다.
                items(room.statuses, key = { "status:${it.sender}" }) { s -> StatusRow(s) }
            }
            if (halted != null) {
                HaltedBox(halted)
            } else if (!room.joined) {
                Text(Strings.notJoined, Modifier.padding(12.dp), color = colors.inkDim)
            } else {
                Composer(draft, onDraft = { draft = it }, onSend = { onSend(draft.trim()); draft = "" })
            }
        }
    }
}

/**
 * 꺼진 자리 안내 상자(입력창 자리): 장작 28 + 「운영자가 이 자리를 닫았어요」 16/600 + 1줄(`room_closed`).
 * 다른 정지 사유는 「이 기기의 대화가 멈췄어요」 + 사유 토큰 모노(정직하게 적는다) + 운영자 안내 1줄.
 */
@Composable
private fun HaltedBox(reason: String) {
    val colors = LocalHandeColors.current
    val shape = RoundedCornerShape(16.dp)
    val closed = reason == "room_closed"
    Row(
        Modifier
            .fillMaxWidth()
            .padding(start = 16.dp, end = 16.dp, bottom = 16.dp, top = 4.dp)
            .clip(shape)
            .background(if (colors.isDay) colors.surface else Color.White.copy(alpha = 0.05f))
            .border(colors.lineWidth, colors.stroke, shape)
            .padding(16.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.Top,
    ) {
        LogIcon(size = 28.dp)
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(if (closed) Strings.roomClosedTitle else Strings.haltedDeviceTitle, color = colors.ink, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            if (closed) {
                Text(Strings.roomClosedBody, color = colors.inkDim, fontSize = 14.sp, lineHeight = 21.sp)
            } else {
                Text(reason, color = colors.inkDim, fontSize = 13.sp, fontFamily = FontFamily.Monospace)
                Text(Strings.haltedDeviceHint, color = colors.inkDim, fontSize = 14.sp, lineHeight = 21.sp)
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
        ) { Icon(HandeIcons.send(colors.onEmber), contentDescription = null, Modifier.size(20.dp), tint = Color.Unspecified) }
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

/**
 * 에이전트 선택지 카드(agent-choices-v1 #620 §3 · 복수 선택 #624): 행 = 체크 상자(둥근 사각) + 번호 + 라벨(최대 3줄) + 「권장」 알약.
 * 행을 누르면 그 행 체크를 토글하고(여러 개 가능), 하나라도 체크돼 있을 때만 [보내기] → 평소 전송 경로(`onSend`)로
 * `AgentChoices.compose` 결과(줄마다 `N. 라벨` — 번호보다 내용이 중요해서, 답 판정 B 로 같은 번호가 된다)를 보낸다. 보내는 동안 카드는 꺼지고,
 * 보낸 글이 타임라인에 오면 상태가 answered 로 바뀌어 한 줄 「✓ 1, 3번 선택 — 라벨1 · 라벨3」 이 된다. 전송이 실패해 글이 안 오면 10초 뒤 다시 켠다.
 * `enabled = false`(꺼진 자리·참여 전)면 고를 수도 보낼 수도 없다.
 */
@Composable
private fun AgentChoicesCard(m: MessageUi, card: AgentChoices.Card, enabled: Boolean, onSend: (String) -> Unit) {
    val colors = LocalHandeColors.current
    val choices = card.choices
    val state = card.state
    if (state is AgentChoices.State.Answered) {
        Text(
            Strings.choiceAnswered(state.numbers, state.numbers.map { choices.labelOf(it) }),
            Modifier.fillMaxWidth(0.82f).padding(start = 4.dp, top = 4.dp, bottom = 2.dp),
            color = colors.agentText, style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis,
        )
        return
    }
    var picked by remember(m.seq) { mutableStateOf(setOf<Int>()) }
    var sending by remember(m.seq) { mutableStateOf(false) }
    LaunchedEffect(sending) {
        if (sending) {
            delay(10_000)
            sending = false
        }
    }
    val active = enabled && !sending
    val shape = RoundedCornerShape(14.dp)
    Column(
        Modifier
            .fillMaxWidth(0.82f)
            .padding(top = 6.dp)
            .clip(shape)
            .background(if (colors.isDay) colors.surface else colors.agent.copy(alpha = 0.06f))
            .border(colors.lineWidth, if (colors.isDay) colors.agent else colors.agent.copy(alpha = 0.35f), shape)
            .alpha(if (active) 1f else 0.6f)
            .padding(vertical = 4.dp),
    ) {
        for (item in choices.items) {
            val on = item.number in picked
            val recommended = choices.recommended == item.number
            Row(
                Modifier
                    .fillMaxWidth()
                    .clickable(enabled = active, role = Role.Checkbox) { picked = if (on) picked - item.number else picked + item.number }
                    .semantics {
                        contentDescription = Strings.choiceRowLabel(item.number, item.label, recommended)
                        toggleableState = if (on) ToggleableState.On else ToggleableState.Off
                    }
                    .padding(horizontal = 12.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalAlignment = Alignment.Top,
            ) {
                Box(
                    Modifier
                        .padding(top = 1.dp)
                        .size(20.dp)
                        .clip(RoundedCornerShape(4.dp))
                        .then(if (on) Modifier.background(colors.ember) else Modifier.border(1.5.dp, colors.inkDim, RoundedCornerShape(4.dp))),
                    contentAlignment = Alignment.Center,
                ) { if (on) Text("✓", color = colors.onEmber, fontSize = 12.sp, fontWeight = FontWeight.Bold) }
                Text("${item.number}", color = colors.agentText, fontWeight = FontWeight.SemiBold, style = MaterialTheme.typography.bodyLarge)
                Text(item.label, Modifier.weight(1f), color = colors.ink, style = MaterialTheme.typography.bodyLarge, maxLines = 3, overflow = TextOverflow.Ellipsis)
                if (recommended) Pill(Strings.choiceRecommended, colors.ink, colors.ember.copy(alpha = 0.22f))
            }
        }
        val canSend = active && picked.isNotEmpty()
        Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp), horizontalArrangement = Arrangement.End) {
            Text(
                Strings.choiceSend,
                Modifier
                    .clip(CircleShape)
                    .background(if (canSend) colors.ember else colors.ember.copy(alpha = 0.35f))
                    .clickable(enabled = canSend, role = Role.Button) {
                        if (picked.isNotEmpty()) {
                            sending = true
                            onSend(AgentChoices.compose(picked, choices.items.map { it.label }))
                        }
                    }
                    .semantics { contentDescription = Strings.choiceSendLabel(picked) }
                    .padding(horizontal = 18.dp, vertical = 8.dp),
                color = colors.onEmber, fontWeight = FontWeight.SemiBold,
            )
        }
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

// ---- 설정(2차-A §A5: 순서 = 자주 → 드물게 → 위험) ----

/**
 * 설정(#584 Play 출시 → 2차-A 재배치): 서버(이름 · 모노 호스트; 「바꾸기」는 Android 에 서버 변경 동작이 없어 표시만) → 화면(밤/낮불 칩 + 힌트) →
 * 이 기기(기기 ID + 「복사」 · 「운영자용 정보」 접힘: 지문·로비 키·키 보관·릴레이) → 기기 관리(「내 기기」, Ready 일 때만) → 위험 구역(「이 기기 지우기」 하나만, 확인 대화상자 →
 * `DeviceHub.wipeDevice`) → 정보(개인정보처리방침 · 데이터 삭제 안내 — `BuildConfig` 링크 · 버전 모노). 계정(로그아웃)·알림은 Android 에 없어 두지 않는다.
 * 계정 = CF Access 신원 + 릴레이 체인의 기기 기록이라 서버 쪽 폐기는 웹 안내로 요청한다(「자세히」에 정직하게 적는다).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    ui: HubUi, onBack: () -> Unit, onWipe: () -> Unit, onNoticeShown: () -> Unit,
    themeMode: HandeThemeMode = HandeThemeMode.NIGHT, onThemeMode: (HandeThemeMode) -> Unit = {},
    relayHost: String? = null, onDevices: (() -> Unit)? = null,
) {
    val colors = LocalHandeColors.current
    val context = LocalContext.current
    val clipboard = LocalClipboardManager.current
    var confirmWipe by rememberSaveable { mutableStateOf(false) }
    var opsOpen by rememberSaveable { mutableStateOf(false) }
    var linkError by remember { mutableStateOf<String?>(null) }
    var toast by remember { mutableStateOf<String?>(null) }
    val isDay = themeMode == HandeThemeMode.DAY
    Scaffold(
        containerColor = Color.Transparent, contentColor = MaterialTheme.colorScheme.onBackground,
        topBar = { HandeTopBar(title = { Text(Strings.settingsTitle) }, navigationIcon = { BackButton(onBack) }) },
        snackbarHost = { NoticeHost(ui.notice ?: linkError ?: toast) { linkError = null; toast = null; onNoticeShown() } },
    ) { pad ->
        Column(
            Modifier.padding(pad).fillMaxSize().verticalScroll(rememberScrollState()).padding(top = 8.dp, bottom = 40.dp),
            verticalArrangement = Arrangement.spacedBy(22.dp),
        ) {
            // 서버
            Column {
                SectionHeader(Strings.settingsServer)
                SectionCard {
                    SectionRow(divider = false) {
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                            Text(ui.server ?: "-", color = colors.ink, fontSize = 17.sp)
                            if (relayHost != null && relayHost != ui.server) {
                                Text(relayHost, color = colors.inkDim, fontSize = 13.sp, fontFamily = FontFamily.Monospace, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            }
                        }
                    }
                }
            }
            // 화면(한데 디자인 1차): 밤이 기본·고정(시스템 라이트 모드를 따르지 않는다), 낮불은 e-ink·밝은 곳용. 고르면 바로 바뀌고 `Settings.theme` 에 남는다.
            // 3차-A: SingleChoiceSegmentedButtonRow(40dp, 선택 = ✓ + 불 22% / 낮불 먹 면 + 종이 글자) — 카드 없이 칸 머리 아래 바로.
            Column {
                SectionHeader(Strings.themeSection)
                Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    HandeSegmented(listOf(Strings.themeChipNight, Strings.themeChipDay), selected = if (isDay) 1 else 0) { i ->
                        onThemeMode(if (i == 1) HandeThemeMode.DAY else HandeThemeMode.NIGHT)
                    }
                    Text(if (isDay) Strings.themeDayHint else Strings.themeNightHint, Modifier.padding(horizontal = 4.dp), color = colors.inkDim, fontSize = 13.sp, lineHeight = 19.sp)
                }
            }
            // 이 기기
            Column {
                SectionHeader(Strings.settingsThisDevice)
                SectionCard {
                    SectionRow(divider = false) {
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                            Text(Strings.deviceIdLabel, color = colors.inkDim, fontSize = 13.sp)
                            Text(ui.deviceId ?: "-", color = colors.ink, fontSize = 15.sp, fontFamily = FontFamily.Monospace)
                        }
                        // content_copy 글리프(3차-A) — 접근성 이름은 「복사」.
                        IconButton(onClick = { ui.deviceId?.let { clipboard.setText(AnnotatedString(it)); toast = Strings.copiedToast } }, enabled = ui.deviceId != null) {
                            Icon(HandeIcons.copy(if (colors.isDay) colors.ink else colors.ember), contentDescription = Strings.copyAction, tint = Color.Unspecified)
                        }
                    }
                    SectionRow(onClick = { opsOpen = !opsOpen }) {
                        Text(Strings.operatorInfo, Modifier.weight(1f), color = colors.inkDim, fontSize = 15.sp)
                        Chevron(down = opsOpen)
                    }
                    if (opsOpen) {
                        val block = buildString {
                            appendLine(Strings.fingerprintLabel)
                            appendLine(SelfService.groupedFingerprint(ui.fingerprint ?: "-"))
                            appendLine("${Strings.lobbyKeys}  ${ui.lobbyLive ?: "-"}/${ui.lobbyMax ?: "-"}")
                            appendLine("${Strings.keyCustody}  ${ui.keyCustody ?: "-"}")
                            append("${Strings.relayLabel}  ${relayHost ?: ui.server ?: "-"}")
                        }
                        val shape = RoundedCornerShape(10.dp)
                        Column(Modifier.padding(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text(
                                block,
                                Modifier.fillMaxWidth().clip(shape).background(if (colors.isDay) colors.surface else Color.Black.copy(alpha = 0.25f))
                                    .border(colors.lineWidth, colors.stroke, shape).padding(horizontal = 12.dp, vertical = 10.dp),
                                color = colors.ink, fontSize = 13.sp, lineHeight = 22.sp, fontFamily = FontFamily.Monospace,
                            )
                            Text(Strings.lobbyHintPlain, color = colors.inkDim, fontSize = 13.sp, lineHeight = 19.sp)
                        }
                    }
                }
            }
            // 기기 관리(#574 「내 기기」) — 허브가 Ready 일 때만 열 수 있다.
            if (onDevices != null) {
                Column {
                    SectionHeader(Strings.settingsDeviceManage)
                    SectionCard {
                        SectionRow(divider = false, onClick = onDevices) {
                            Text(Strings.devicesTitle, Modifier.weight(1f), color = colors.ink, fontSize = 17.sp)
                            if (ui.candidates.isNotEmpty()) Box(Modifier.size(8.dp).clip(CircleShape).background(colors.ember).semantics { contentDescription = Strings.candidatesTitle })
                            Chevron()
                        }
                    }
                }
            }
            // 위험 구역 — 「이 기기의 키와 대화가 모두 지워집니다」 + 「이 기기 지우기」 하나만. 서버 기록·새 ID 이야기는 「자세히」. 낮불은 흰 면 + 2px #A8321C(2차-B).
            Column {
                SectionHeader(Strings.settingsDanger, color = colors.warnText)
                val shape = RoundedCornerShape(16.dp)
                Column(
                    Modifier
                        .padding(horizontal = 16.dp)
                        .fillMaxWidth()
                        .clip(shape)
                        .then(if (colors.isDay) Modifier.background(colors.surface).border(2.dp, colors.warn, shape) else Modifier.border(1.5.dp, colors.warn.copy(alpha = 0.5f), shape))
                        .padding(14.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    DetailDisclosure(hint = Strings.wipeDangerBody, detail = Strings.wipeDeviceHint)
                    DangerButton(Strings.wipeDevice) { confirmWipe = true }
                }
            }
            // 정보(#584 Play): 정책 링크 2개(open_in_new 글리프 — Custom Tabs, 없으면 ACTION_VIEW) + 버전.
            Column {
                SectionHeader(Strings.aboutSection)
                SectionCard {
                    SectionRow(divider = false, onClick = { openPolicy(context, BuildConfig.PRIVACY_URL) { linkError = Strings.openLinkFailed } }) {
                        Text(Strings.privacyPolicy, Modifier.weight(1f), color = colors.ink, fontSize = 17.sp)
                        OpenInNewGlyph()
                    }
                    SectionRow(onClick = { openPolicy(context, BuildConfig.DELETE_ACCOUNT_URL) { linkError = Strings.openLinkFailed } }) {
                        Text(Strings.deleteDataGuide, Modifier.weight(1f), color = colors.ink, fontSize = 17.sp)
                        OpenInNewGlyph()
                    }
                    SectionRow {
                        Text(Strings.versionShort, Modifier.weight(1f), color = colors.ink, fontSize = 17.sp)
                        Text(Strings.versionLine(BuildConfig.VERSION_NAME, BuildConfig.VERSION_CODE), color = colors.inkDim, fontSize = 14.sp, fontFamily = FontFamily.Monospace)
                    }
                }
            }
        }
    }
    if (confirmWipe) WipeConfirmDialog(onConfirm = { confirmWipe = false; onWipe() }, onDismiss = { confirmWipe = false })
}

/** 행 끝 open_in_new 18dp(밖에서 열리는 링크 — 정책 페이지). 장식이라 접근성 이름 없음(행 글자가 이름). */
@Composable
private fun OpenInNewGlyph() {
    val colors = LocalHandeColors.current
    Icon(HandeIcons.openInNew(colors.inkDim), contentDescription = null, Modifier.size(18.dp), tint = Color.Unspecified)
}

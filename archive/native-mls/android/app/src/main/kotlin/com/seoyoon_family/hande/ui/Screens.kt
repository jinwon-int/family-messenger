// 화면 3 + 1(#338 B1 골격): 처음 설정 · 등록 대기/세션 · 대화방 목록 · 대화. 꾸밈 없이 코어 동작을 눌러 볼 수 있는 최소 UI — C 단계가 다듬는다.
// #574 PR 4: 등록 대기의 형제 승인 모드(큰 지문·만료) · 목록 위의 「새 기기 승인」 카드 · 「내 기기」(registrar 부여/해제).
// #584 PR 3: 처음 설정의 서버 주소는 도메인만 — 「서버 찾기」(`.well-known/hande`) 가 서버 이름·주소를 보여 준 뒤 저장, 목록 제목 아래 서버 이름.
// #584 Play 출시: 「설정」(정보 · 개인정보처리방침 · 계정 및 데이터 삭제 링크 · 「이 기기 지우기」) — 등록 대기·로그인·목록·오류 화면 어디서나 연다(Play 정책: 앱 안 링크 + 앱 내 삭제 경로).
//   Android 16(targetSdk 36)은 edge-to-edge 강제(adjustResize 무효) → 입력 화면은 `imePadding`/`safeDrawingPadding`, 뒤로가기는 `BackHandler`(predictive back 기본 켜짐).
// 한데 디자인 1차(2026-10-31, docs/design/HANDE-DESIGN-SYSTEM.md): 토큰은 `ui/theme/HandeTheme.kt`(`LocalHandeColors`), 모닥불 배경 위에 투명 Scaffold/앱바 ·
//   목록 = 「자리」(불 세기 불꽃 · 좌석 점 · 안 읽음 주황 점; 「불지기」 배지는 오너 결정 #613/#540 으로 없음) · 대화 = 말풍선(면/불/파랑) + 알약 입력창 · 설정 「화면」(밤/낮불).
// 한데 디자인 2차-A(§A1~A6, iOS 전 화면의 M3 판 — 조각은 `ui/theme/HandeKit.kt`): 온보딩 4단계(진행 막대 · ① 서버 찾기 → ② 이름 → ③ 가족 로그인 → ④ 이 기기 등록) ·
//   새 기기 승인 전체 화면(`ApproveScreen`: 8행을 모두 눌러 표시해야 「승인」) · 목록 빈 상태 그림 · 꺼진 자리 안내 상자 · 설정 재배치(자주 → 드물게 → 위험).
//   Android 에 데이터가 없는 것(알림함·오프닝·로그아웃·서버 바꾸기·전송 상태·타닥타닥·폐기)은 그리지 않는다. 허브 호출·단계 매핑은 그대로.
// #715 · #549: 대화 목록 순서 편집(머리의 순서 아이콘 → 「자리 순서」 모드: 행마다 「맨 위로 고정」·▲▼, 방은 열리지 않음) — 순서는 릴레이에 actor 단위로 동기화(`RoomOrderSync`).
// 한데 디자인 3차-A(Android Material 3 관용구): 투명 TopAppBar(64dp, 제목 왼쪽, 아이콘 버튼) · M3 OutlinedTextField(떠 있는 라벨 · isError + supportingText) · M3 Button/OutlinedButton/TextButton(알약) ·
//   목록 머리 = 큰 워드마크 + 설정 아이콘, ExtendedFloatingActionButton(56 · 반경 16) = 「참여 요청」(방 만들기가 없어 iOS 「불 피우기」의 Android 짝) · 설정 「화면」 = SingleChoiceSegmentedButtonRow ·
//   「이 기기 지우기」 확인 = AlertDialog(반경 28, surfaceContainerHigh) — 바텀시트 없음 · 등록되면 목록 + Snackbar 「등록됐어요 — 불 곁으로 오세요」 · 「등록 정보 공유」 = OutlinedButton + share ·
//   정책 링크 행은 open_in_new. 아이콘은 `ui/theme/HandeIcons.kt`(2차-B 아이콘 세트 + Material Symbols 짝 글리프, 라이브러리 의존 없음).
// 2차-B 낮불 세부: 꺼진 자리 = 흐림 대신 점선 1.5 회색 테두리 + 회색 글자 · 안 읽음 = 먹 알약 「새 글」 + 이름 800 · 승인 표시 = 먹 채움 + 종이 ✓ · 위험 구역 2px · 토스트 먹 면.
//   전송 상태 말풍선(#837): 보내는 즉시 「보내는 중…」, 실패하면 「전송 안 됨 · 다시 보내기」(`RoomUi.outgoing` → `OutgoingRow`). 「연결되면」은 없다(대기열 글도 보내는 중).
// #833 하드웨어 키보드 단축키(iOS 규칙 전체, End = Esc): 대화방(작성창 · 대화 읽기 · 선택 모드 + 「선택해서 복사」 창) · 목록(PageUp/Down 표시 · Enter 열기) ·
//   선택지 Alt+숫자 — 판정은 `core/HardwareKeys`·`AgentChoiceKeys`, 키 읽기는 `ui/HardwareKeyInput.kt`. 방별 초안은 `SaveableStateHolder`.
package com.seoyoon_family.hande.ui

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.focusable
import androidx.compose.foundation.gestures.animateScrollBy
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectableGroup
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
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.produceState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawOutline
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.inset
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isAltPressed
import androidx.compose.ui.input.key.isCtrlPressed
import androidx.compose.ui.input.key.isMetaPressed
import androidx.compose.ui.input.key.isShiftPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreInterceptKeyBeforeSoftKeyboard
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.seoyoon_family.hande.core.AttachmentFiles
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.toggleableState
import androidx.compose.ui.state.ToggleableState
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.seoyoon_family.hande.BuildConfig
import com.seoyoon_family.hande.core.AgentActors
import com.seoyoon_family.hande.core.AgentChoiceKeys
import com.seoyoon_family.hande.core.AgentChoices
import com.seoyoon_family.hande.core.AgentMarkdown
import com.seoyoon_family.hande.core.AgentSkills
import com.seoyoon_family.hande.core.AlertRefs
import com.seoyoon_family.hande.core.RoomListReturn
import com.seoyoon_family.hande.core.RoomListSlot
import com.seoyoon_family.hande.core.AppLogin
import com.seoyoon_family.hande.core.BottomFollow
import com.seoyoon_family.hande.core.CandidateUi
import com.seoyoon_family.hande.core.DeviceHub
import com.seoyoon_family.hande.core.FingerprintRows
import com.seoyoon_family.hande.core.HardwareKeys
import com.seoyoon_family.hande.core.HardwareKeys.RoomAction
import com.seoyoon_family.hande.core.HardwareKeys.RoomMode
import com.seoyoon_family.hande.core.HandeThemeMode
import com.seoyoon_family.hande.core.HubUi
import com.seoyoon_family.hande.core.LinkPreviews
import com.seoyoon_family.hande.core.PreviewSites
import com.seoyoon_family.hande.core.ReplyQuote
import com.seoyoon_family.hande.core.SwipeReply
import com.seoyoon_family.hande.core.LoginLauncher
import com.seoyoon_family.hande.core.MessageUi
import com.seoyoon_family.hande.core.OutgoingUi
import com.seoyoon_family.hande.core.Phase
import com.seoyoon_family.hande.core.RoomUi
import com.seoyoon_family.hande.core.SelfService
import com.seoyoon_family.hande.core.ServerDiscovery
import com.seoyoon_family.hande.core.Settings
import com.seoyoon_family.hande.core.StatusUi
import com.seoyoon_family.hande.core.TextLinks
import com.seoyoon_family.hande.core.ThumbnailSizing
import com.seoyoon_family.hande.ui.theme.CampfireBackground
import com.seoyoon_family.hande.ui.theme.Chevron
import com.seoyoon_family.hande.ui.theme.CreamButton
import com.seoyoon_family.hande.ui.theme.DangerButton
import com.seoyoon_family.hande.ui.theme.DayTickedRow
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
import com.seoyoon_family.hande.ui.theme.fixedSp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
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
    // #833 하드웨어 키보드: 방마다 화면 상태(작성 중인 글 등)를 따로 둔다 — PageUp/PageDown 으로 방을 넘겨도 초안이 방별로 남는다.
    // `lastRoom` = 방금 나온 방(목록 PageUp/PageDown 의 출발점). `arrowStep` = 설정 「↑/↓ 키 이동」.
    val roomStates = rememberSaveableStateHolder()
    var lastRoom by rememberSaveable { mutableStateOf<String?>(null) }
    LaunchedEffect(openRoom) { openRoom?.let { lastRoom = it } }
    // 대화 목록의 스크롤 위치(오너 요청 2026-11-24): 방을 열면 목록 화면이 통째로 빠졌다가 돌아올 때 새로 그려져 늘 맨 위였다.
    // 목록 밖(여기)에 두고 저장해서, 방에서 나오면(앱의 뒤로·시스템 뒤로 모두) 들어가기 전 위치 그대로 돌아온다(프로세스 복원 포함).
    val roomListState = rememberSaveable(saver = LazyListState.Saver) { LazyListState() }
    var arrowStep by remember { mutableStateOf(HardwareKeys.ArrowScrollStep.from(hub.settings.arrowScrollStep)) }
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
                onSiblingRescan = if (ui.phase is Phase.Ready) hub::setSiblingRescan else null,
                arrowStep = arrowStep, onArrowStep = { arrowStep = it; hub.settings.arrowScrollStep = it.raw },
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
            Phase.Setup -> SetupScreen(hub.settings, hub::discover) { hub.start() }
            is Phase.WaitingEnrollment -> EnrollScreen(ui, phase, onSettings = { showSettings = true }, onWipe = wipe) { hub.retryEnrollment(scope) }
            Phase.NeedsLogin -> {
                val context = LocalContext.current
                LoginScreen(hub.settings, ui, onGoogle = { hub.beginLogin(context) }, onSaved = { hub.reconfigure(scope) }, onSettings = { showSettings = true }, onNoticeShown = hub::clearNotice)
            }
            is Phase.Fatal -> MessageScreen("앱을 시작할 수 없습니다", phase.message, action = { TextButton(onClick = { showSettings = true }) { Text(Strings.settingsButton) } })
            Phase.Starting -> MessageScreen(Strings.appName, Strings.starting)
            // #766 B: `Stored`(저장된 방·대화 먼저 — 세션 확인 전)와 `Ready` 는 같은 가지다 — `Ready` 로 넘어가도 열린 방·스크롤·작성 중인 글이 그대로다.
            // `Stored` 에서는 세션이 필요한 것(보내기·첨부·선택지 답·링크 미리보기·내 기기)을 꺼 둔다. 「연결 중입니다…」는 `ui.connecting` 이 보인다.
            Phase.Stored, Phase.Ready -> {
                val live = phase is Phase.Ready
                val room = openRoom?.let { name -> ui.rooms.firstOrNull { it.room == name } }
                if (room != null) {
                    // 보고 있는 방의 읽음 위치(#571 후속): 열 때 한 번, 그 뒤 마지막 seq 가 움직일 때마다(새 글·내 전송) · 세션이 확인될 때(#766 B).
                    LaunchedEffect(room.room, room.messages.lastOrNull()?.seq, live) { hub.markRead(scope, room.room) }
                    roomStates.SaveableStateProvider(room.room) {
                    RoomScreen(
                        room, ui, onBack = { openRoom = null }, onSend = { text -> hub.send(room.room, text) }, onNoticeShown = hub::clearNotice,
                        onRetrySend = { id -> hub.retrySend(room.room, id) },
                        previews = if (live) hub.linkPreviews else null,
                        onOpenAttachment = { seq -> hub.openAttachment(room.room, seq) },
                        onAttachmentPreview = { seq -> hub.attachmentPreview(room.room, seq) },
                        onSendAttachment = { bytes, name -> hub.sendAttachment(scope, room.room, bytes, name) },
                        live = live,
                        // #833 PageUp/PageDown: 목록 순서의 이전·다음 방(끝에서는 그대로).
                        onSwitchRoom = { step -> HardwareKeys.neighbor(room.room, ui.rooms.map { it.room }, step)?.let { openRoom = it } },
                        arrowStep = arrowStep,
                    )
                    }
                } else if (showDevices && live) {
                    LaunchedEffect(Unit) { hub.refreshDevices(scope) }
                    DevicesScreen(ui, onBack = { showDevices = false }, onGrant = { hub.setRoles(scope, it, true) }, onRelease = { hub.setRoles(scope, it, false) }, onNoticeShown = hub::clearNotice)
                } else {
                    // 「내 기기」는 설정 → 기기 관리에서 연다(3차-A: 목록 오른쪽 위는 설정 아이콘 하나).
                    RoomListScreen(
                        ui, onOpen = { openRoom = it }, onRequestJoin = { hub.requestJoin(scope) },
                        onCompare = { approveId = it }, onIgnore = { hub.dismissCandidate(scope, it) },
                        onSettings = { showSettings = true }, onNoticeShown = hub::clearNotice,
                        onMoveRoom = hub::moveRoom, onMoveRoomToTop = hub::moveRoomToTop,
                        anchorRoom = lastRoom,
                        roomListState = roomListState,
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

/**
 * 대화 목록 행의 알약(「새 글」·「답변 필요」): 면 색 + 12 굵은 글자 한 줄.
 * 높이를 20dp 로 고정하면 시스템 글자 크기를 키운 기기(예: 1.3배)에서 글자가 20dp 를 넘어 아래가 잘린다 —
 * 20dp 는 **최소** 높이로만 두고 글자에 맞춰 자라게 한다. 모서리는 높이의 절반(`CircleShape`)이라 자라도 알약 모양이다.
 */
@Composable
private fun ListPill(label: String, fill: Color, text: Color) {
    Box(
        Modifier.heightIn(min = 20.dp).clip(CircleShape).background(fill).padding(horizontal = 7.dp, vertical = 1.dp),
        contentAlignment = Alignment.Center,
    ) { Text(label, color = text, fontSize = 12.sp, lineHeight = 16.sp, fontWeight = FontWeight.Bold, maxLines = 1, softWrap = false) }
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
 * 대화 목록 = 「자리」(3차-A A2): 머리는 TopAppBar 대신 큰 워드마크(34) + 「오늘 밤, 모닥불에 한데 모여」 + 서버 이름(#584), 오른쪽 위는 순서 편집(자리 2개 이상) + 설정 아이콘
 * (초대 벨은 Android 에 그 데이터가 없다; 「내 기기」는 설정 → 기기 관리). 낮불은 머리 아래 먹 선 1.5(2차-B). 방 행 카드(`RoomRow`).
 * 순서 편집(#549 · #715, iOS 「↕ 순서」 모드와 같은 결): 머리가 「자리 순서」 + 주황 「완료」 + 안내 한 줄로 바뀌고, 행은 `OrderRow`(이름 + 「맨 위로 고정」 + ▲▼, 끝에서는 비활성).
 * 행을 눌러도 방이 열리지 않는다. 뒤로 가기 = 편집 끝. 자리가 1개 이하가 되면 조용히 끈다. 옮기면 허브가 로컬에 바로 저장하고 릴레이에 올린다(`DeviceHub.moveRoom`).
 * `ExtendedFloatingActionButton`(56 · 반경 16 · 오른쪽 아래 16dp · 불 면) — iOS 「불 피우기」의 Android 짝이지만 Android 에는 방 만들기가 없어 기존 동작 「참여 요청」(로비 키 게시)을 단다(의도된 차이).
 * 빈 상태(2차-A §A3): 꺼진 장작 그림(불 그림은 여기만) + 「아직 피운 모닥불이 없습니다」 + 1줄.
 * 등록 직후(허브가 WaitingEnrollment → Ready 전환에 `enrolledNow` 알림을 싣는다)는 토스트 대신 M3 Snackbar 「등록됐어요 — 불 곁으로 오세요」.
 * 기기 ID·로비 키·키 보관은 설정 → 이 기기 → 운영자용 정보로 옮겼다(목록 아래 줄 없음).
 */
@Composable
fun RoomListScreen(
    ui: HubUi, onOpen: (String) -> Unit, onRequestJoin: () -> Unit,
    onCompare: (String) -> Unit, onIgnore: (String) -> Unit, onSettings: () -> Unit, onNoticeShown: () -> Unit,
    onMoveRoom: (String, Int) -> Unit = { _, _ -> }, onMoveRoomToTop: (String) -> Unit = {},
    /** 방금 나온 방(#833) — 표시가 없을 때 PageUp/PageDown 의 출발점. 돌아왔을 때 이 방이 화면에 보이게 한다. */
    anchorRoom: String? = null,
    /** 목록 스크롤 위치 — 호출자(HandeRoot)가 들고 있어야 방에 들어갔다 나와도 남는다. */
    roomListState: LazyListState = rememberLazyListState(),
) {
    val colors = LocalHandeColors.current
    val snackbar = remember { SnackbarHostState() }
    val canReorder = ui.rooms.size > 1
    var editing by rememberSaveable { mutableStateOf(false) }
    val ordering = editing && canReorder
    // #833 하드웨어 키보드: PageUp/PageDown = 표시 행을 한 칸씩(열지 않음, 테두리) · Enter = 표시된 행 열기 · 순서 모드에서는 움직이지 않음.
    // 키를 받으려면 화면 안에 포커스가 있어야 해서 목록 뿌리를 포커스 대상으로 두고 화면이 뜰 때 포커스를 준다. Esc 는 판정하지 않는다(시스템 「뒤로」 그대로).
    var highlighted by remember { mutableStateOf<Int?>(null) }
    val listFocus = remember { FocusRequester() }
    val listKeys = remember { HeldKeys() }
    LaunchedEffect(Unit) { runCatching { listFocus.requestFocus() } }
    // 방에서 돌아왔을 때: 위치는 roomListState 가 그대로 들고 있다. 그 사이 순서가 바뀌어(맨 위로 올림 등) 방금 나온 방이
    // 화면 밖이면 그 방이 보이게 옮긴다 — 보이면 손대지 않는다. 첫 배치가 끝난 뒤에 판단한다(배치 전에는 보이는 항목이 비어 있다).
    LaunchedEffect(Unit) {
        if (anchorRoom == null || ui.rooms.isEmpty()) return@LaunchedEffect
        snapshotFlow { roomListState.layoutInfo.totalItemsCount }.first { it > 0 }
        val visible = roomListState.layoutInfo.visibleItemsInfo.map { it.index }
        RoomListReturn.scrollTarget(ui.rooms.map { it.room }, anchorRoom, visible)?.let { roomListState.scrollToItem(it) }
    }
    LaunchedEffect(highlighted) { highlighted?.let { if (it in ui.rooms.indices) roomListState.reveal(it) } }
    val onListKey: (KeyEvent) -> Boolean = { event ->
        !event.fromSoftKeyboard() && listKeys.dispatch(event) {
            val press = event.hardwarePress()
            val anchor = anchorRoom?.let { a -> ui.rooms.indexOfFirst { it.room == a }.takeIf { it >= 0 } }
            when (val action = press?.let { HardwareKeys.listAction(it, ui.rooms.size, highlighted, anchor, ordering) }) {
                is HardwareKeys.ListAction.Highlight -> { highlighted = action.index; true }
                is HardwareKeys.ListAction.Open -> { onOpen(ui.rooms[action.index].room); true }
                null -> false
            }
        }
    }
    LaunchedEffect(canReorder) { if (!canReorder) editing = false }
    BackHandler(enabled = ordering) { editing = false }
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
            // 순서 편집 중에는 숨긴다 — 마지막 행의 ▼ 를 가리지 않고, 편집 모드가 바뀐 것이 분명하게.
            if (!ordering) ExtendedFloatingActionButton(
                text = { Text(Strings.requestJoin, fontSize = 16.sp, fontWeight = FontWeight.SemiBold) },
                icon = { Icon(HandeIcons.add(colors.onEmber), contentDescription = null, tint = Color.Unspecified) },
                onClick = onRequestJoin,
                shape = RoundedCornerShape(16.dp),
                containerColor = colors.ember,
                contentColor = colors.onEmber,
            )
        },
    ) { pad ->
        Column(Modifier.padding(pad).fillMaxSize().onPreviewKeyEvent(onListKey).focusRequester(listFocus).focusable()) {
            if (ordering) {
                OrderHeader(hint = Strings.orderHint(ui.roomOrderSynced), onDone = { editing = false })
            } else {
                Row(Modifier.fillMaxWidth().padding(start = 20.dp, end = 8.dp, top = 16.dp, bottom = 10.dp), verticalAlignment = Alignment.Bottom) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        HandeWordmark(size = 34.sp)
                        // 연결 중이면 부제 자리에 그 사실을.
                        Text(if (ui.connecting) Strings.connecting else Strings.campfireSubtitle, color = colors.inkDim, fontSize = 15.sp)
                        // 서버 이름(#584)은 여기 두지 않는다 — 웹·iOS 목록 머리와 같게 워드마크 + 부제만. 어느 서버인지는 설정 화면 「서버」 줄에 있다.
                    }
                    // #549 · #715: 순서 편집 진입(iOS 「↕ 순서」·웹 reorder 아이콘). 자리가 0~1개면 숨김. 「완료」는 편집 머리에만.
                    if (canReorder) {
                        IconButton(onClick = { editing = true }) { Icon(HandeIcons.reorder(colors), contentDescription = Strings.orderEditLabel, tint = Color.Unspecified) }
                    }
                    IconButton(onClick = onSettings) { Icon(HandeIcons.settings(colors.ink), contentDescription = Strings.settingsButton, tint = Color.Unspecified) }
                }
            }
            if (colors.isDay) HorizontalDivider(thickness = 1.5.dp, color = colors.ink)
            // 새 기기 승인 요청(#574): 등록 기기(또는 registrar 없는 actor 의 활성 기기)에게만 보인다. 「지문 비교」→ 전체 화면 `ApproveScreen`.
            if (ui.candidates.isNotEmpty() && !ordering) {
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
                LazyColumn(Modifier.weight(1f), state = roomListState, contentPadding = PaddingValues(top = 6.dp, bottom = 88.dp)) {
                    if (ordering) {
                        val last = ui.rooms.lastIndex
                        itemsIndexed(ui.rooms, key = { _, r -> r.room }) { i, r ->
                            OrderRow(
                                r, isFirst = i == 0, canUp = i > 0, canDown = i < last,
                                onUp = { onMoveRoom(r.room, -1) }, onDown = { onMoveRoom(r.room, 1) }, onTop = { onMoveRoomToTop(r.room) },
                            )
                        }
                    } else {
                        itemsIndexed(ui.rooms, key = { _, r -> r.room }) { i, r -> RoomRow(r, highlighted = highlighted == i) { onOpen(r.room) } }
                    }
                }
            }
        }
    }
}

/** 순서 편집 머리(iOS 디자인 2차 2c): 「자리 순서」 22/600 + 오른쪽 주황 알약 「완료」 + 안내 한 줄. */
@Composable
private fun OrderHeader(hint: String, onDone: () -> Unit) {
    val colors = LocalHandeColors.current
    Column(Modifier.fillMaxWidth().padding(start = 20.dp, end = 16.dp, top = 20.dp, bottom = 12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(
                Strings.orderModeTitle, color = colors.ink, fontSize = 22.sp, fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f).semantics { heading() },
            )
            val pill = RoundedCornerShape(18.dp)
            Box(
                Modifier
                    .heightIn(min = 48.dp)
                    .clip(pill)
                    .clickable(role = Role.Button, onClick = onDone)
                    .semantics { contentDescription = Strings.orderDoneLabel },
                contentAlignment = Alignment.Center,
            ) {
                Box(
                    Modifier
                        .height(36.dp)
                        .clip(pill)
                        .background(colors.ember)
                        .then(if (colors.isDay) Modifier.border(colors.lineWidth, colors.stroke, pill) else Modifier)
                        .padding(horizontal = 16.dp),
                    contentAlignment = Alignment.Center,
                ) { Text(Strings.orderDone, color = colors.onEmber, fontSize = 16.sp, fontWeight = FontWeight.SemiBold) }
            }
        }
        Text(hint, color = colors.inkDim, fontSize = 14.sp, lineHeight = 20.sp)
    }
}

/**
 * 순서 편집 행(iOS `OrderRow` 와 같은 결): 카드 안에 이름 17/600 + 보조 13(맨 앞 = 「맨 위 고정」 · 꺼진 자리 = 「불이 꺼진 자리 · 운영자가 닫음」) +
 * 「맨 위로 고정」(맨 앞·꺼진 자리는 비활성) + ▲▼(끝에서는 비활성, 웹 한데 ▲▼). 불 세기·미리보기·안 읽음은 숨긴다. 눌러도 방은 열리지 않는다.
 */
@Composable
private fun OrderRow(r: RoomUi, isFirst: Boolean, canUp: Boolean, canDown: Boolean, onUp: () -> Unit, onDown: () -> Unit, onTop: () -> Unit) {
    val colors = LocalHandeColors.current
    val day = colors.isDay
    val halted = r.halted != null
    val closedDay = halted && day
    val shape = RoundedCornerShape(16.dp)
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 5.dp)
            .alpha(if (halted && !day) 0.6f else 1f)
            .clip(shape)
            .background(colors.surface)
            .then(if (closedDay) Modifier.dashedBorder(1.5.dp, colors.ash, shape) else Modifier.border(colors.lineWidth, colors.stroke, shape))
            .padding(start = 14.dp, end = 6.dp, top = 6.dp, bottom = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(
                AgentActors.roomLabel(r.room), color = if (closedDay) colors.ash else colors.ink, fontSize = 17.sp, lineHeight = 22.sp,
                fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
            val note = when {
                halted -> if (r.halted == "room_closed") Strings.roomClosedPreview else "${Strings.halted} · ${r.halted}"
                isFirst -> Strings.orderPinnedNote
                else -> null
            }
            if (note != null) {
                Spacer(Modifier.height(2.dp))
                Text(note, color = colors.inkDim, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        TextButton(onClick = onTop, enabled = !isFirst && !halted) {
            Text(Strings.orderPinTop, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = if (!isFirst && !halted) colors.ember else colors.inkDim.copy(alpha = 0.5f))
        }
        Column {
            OrderStepButton("▲", Strings.orderUp(r.room), canUp, onUp)
            OrderStepButton("▼", Strings.orderDown(r.room), canDown, onDown)
        }
    }
}

/** ▲/▼ 한 칸(48×32 — 두 개 겹쳐 64, 끌기가 어려운 조부모용). 끝에서는 비활성(흐린 글자). */
@Composable
private fun OrderStepButton(symbol: String, label: String, enabled: Boolean, onClick: () -> Unit) {
    val colors = LocalHandeColors.current
    Box(
        Modifier
            .size(width = 48.dp, height = 32.dp)
            .clip(RoundedCornerShape(8.dp))
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        Text(symbol, color = if (enabled) colors.ember else colors.inkDim.copy(alpha = 0.35f), fontSize = 15.sp, fontWeight = FontWeight.Bold)
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
private fun RoomRow(r: RoomUi, highlighted: Boolean = false, onOpen: () -> Unit) {
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
    // #870: 마지막 글의 [답변 필요] 카드가 열렸는가(웹·iOS 와 같은 판정). 저장된 글에서 매번 계산하고 저장하지 않는다.
    val answer = remember(r.messages) { AgentChoices.roomAnswer(r.messages) }
    val slot = RoomListSlot.kind(halted = halted, joined = r.joined, working = r.working, answer = answer)
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 5.dp)
            .alpha(if (halted && !day) 0.6f else 1f)
            .clip(shape)
            .background(colors.surface)
            // #833 키보드 PageUp/PageDown 으로 표시한 행(열지 않음). 2dp 포커스 테두리만으로는 안 보였다 — 낮불은 포커스 색(#1A1510)이
            // 평소 테두리(stroke #1A1510 · 1.5dp)와 같아 0.5dp 차이뿐, 밤은 크림 실선 하나. 그래서 면 + 3dp 테두리 + 왼쪽 6dp 띠로 표시한다.
            // 낮불은 투명도 금지(2차-B) → 불투명 표시 행 면 #EFE9DC(HandeKit DayTickedRow) · 밤은 크림 14% 면.
            .then(
                if (highlighted) {
                    Modifier
                        .background(if (day) DayTickedRow else colors.focus.copy(alpha = 0.14f))
                        .drawBehind { drawRect(colors.focus, size = size.copy(width = 6.dp.toPx())) }
                        .border(3.dp, colors.focus, shape)
                } else if (closedDay) {
                    Modifier.dashedBorder(1.5.dp, colors.ash, shape)
                } else {
                    Modifier.border(colors.lineWidth, colors.stroke, shape)
                },
            )
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
            // 자리 점은 이름 옆에(오너 2026-10-31, iOS `CampfireCard` 와 같다): 맨 아래 줄을 점만 차지하지 않게. 이름이 길면 이름이 줄고 점은 그대로.
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    AgentActors.roomLabel(r.room), color = textColor, fontSize = 17.sp, lineHeight = 22.sp,
                    fontWeight = if (day && r.unread) FontWeight.ExtraBold else FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )
                SeatDots(r.messages)
                // #870(AGENT-CHOICES §7): 마지막 글의 [답변 필요] 카드가 열린 방 — 「새 글」 알약과 같은 모양(`ListPill`), 에이전트 색 면.
                if (slot == RoomListSlot.Kind.ANSWER) {
                    Spacer(Modifier.width(6.dp))
                    ListPill(Strings.answerNeededPill, fill = colors.agentText, text = colors.bgTop)
                }
            }
            Spacer(Modifier.height(3.dp))
            // 미리보기 자리: 꺼진 자리·참여 전 > 답변 필요(#870) > status-v1 「⏳ Working/대기 중」 줄(#560, 오너 2026-10-30) > 마지막 글.
            val preview = when (slot) {
                RoomListSlot.Kind.HALTED -> if (r.halted == "room_closed") Strings.roomClosedPreview else "${Strings.halted} · ${r.halted}"
                RoomListSlot.Kind.NOT_JOINED -> Strings.notJoined
                RoomListSlot.Kind.ANSWER -> Strings.answerNeededPreview(answer!!)
                RoomListSlot.Kind.WORKING -> r.working.orEmpty()
                RoomListSlot.Kind.PREVIEW -> r.messages.lastOrNull()?.text?.let { ReplyQuote.visibleText(it) } ?: ""
            }
            val workingShown = slot == RoomListSlot.Kind.WORKING
            val answerShown = slot == RoomListSlot.Kind.ANSWER
            Text(
                preview, fontSize = 15.sp, lineHeight = 20.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                color = when {
                    answerShown -> colors.ink
                    workingShown -> colors.ember
                    closedDay -> colors.ash
                    else -> colors.inkDim
                },
                fontWeight = if (workingShown || answerShown) FontWeight.SemiBold else FontWeight.Normal,
                modifier = if (answerShown) Modifier.semantics { contentDescription = Strings.answerNeededA11y(answer!!) } else Modifier,
            )
        }
        // 안 읽음(#571 후속): 밤 = 주황 점 하나 + 빛남(개수 없음 — 글자는 접근성 문구로만) · 낮불 = 먹 알약 「새 글」(`ListPill` — 최소 20dp · 종이 12 굵게).
        // 같은 사람의 다른 기기(PC 웹·iPhone)에서 읽으면 다음 poll 에 꺼진다.
        if (r.unread) {
            Spacer(Modifier.width(8.dp))
            if (day) {
                ListPill(Strings.newPostPill, fill = colors.ink, text = colors.bgTop)
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
 * 좌석 점(이름 옆): 글을 쓴 사람(actor 단위 — 같은 사람의 여러 기기는 한 점, 최대 5) 크림 ● 뒤에 에이전트(노드 단위) 파랑 ● — 합쳐 최대 6.
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
    Row(Modifier.padding(start = 8.dp), horizontalArrangement = Arrangement.spacedBy(5.dp), verticalAlignment = Alignment.CenterVertically) {
        repeat(personCount) { SeatDot(agent = false) }
        repeat(agentCount) { SeatDot(agent = true) }
    }
}

/**
 * 대화방(한데 디자인 1차): 말풍선(`MessageRow`) · 작업 상태(`StatusRow`) · 알약 입력창 + 주황 보내기 원(`Composer`).
 * 꺼진 자리(2차-A §A6): 제목 아래 「불이 꺼진 자리」, 지난 말풍선 60%, 입력창 자리를 안내 상자(`HaltedBox`)로 교체 — 「덮어 두기」(보관)는 Android 에 없어 두지 않는다.
 * 하드웨어 키보드(#833): 판정은 `core/HardwareKeys`·`AgentChoiceKeys`, 모드 = 작성창 포커스(작성창) · 타임라인 포커스(대화 읽기) · 키로 고른 말풍선(선택 모드).
 */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun RoomScreen(
    room: RoomUi, ui: HubUi, onBack: () -> Unit, onSend: (String) -> Unit, onNoticeShown: () -> Unit, previews: LinkPreviews? = null,
    onOpenAttachment: (suspend (Long) -> AttachmentFiles.OpenResult)? = null,
    onSendAttachment: ((ByteArray, String?) -> Unit)? = null,
    onAttachmentPreview: (suspend (Long) -> ThumbnailSizing.Preview?)? = null,
    /** 세션이 확인됐나(#766 B, `Phase.Ready`). 아니면 저장된 대화만 보이는 중 — 보내기·첨부·선택지 답을 꺼 둔다. */
    live: Boolean = true,
    /** #837: 「전송 안 됨」 말풍선의 「다시 보내기」(보내는 글 id). */
    onRetrySend: ((Long) -> Unit)? = null,
    /** #833 PageUp(-1)/PageDown(+1) — 목록 순서의 이전·다음 방으로. null 이면 키를 먹기만 한다. */
    onSwitchRoom: ((Int) -> Unit)? = null,
    /** #833 설정 「↑/↓ 키 이동」. */
    arrowStep: HardwareKeys.ArrowScrollStep = HardwareKeys.ArrowScrollStep.STANDARD,
) {
    val colors = LocalHandeColors.current
    // #366 C · #338 C 단계 — 첨부: 말풍선을 누르면 열고(이미지는 화면 안 뷰어, 그 밖은 다른 앱으로), 작성창 📎 로 파일을 골라 보낸다.
    // 연 바이트는 화면 상태에만 있고 이력에는 저장하지 않는다(FILE-V2 §4-2). 한 번에 하나만 연다.
    val attachScope = rememberCoroutineScope()
    val attachContext = LocalContext.current
    var opening by remember(room.room) { mutableStateOf<Long?>(null) }
    var viewing by remember(room.room) { mutableStateOf<AttachmentFiles.Opened?>(null) }
    val toast: (String) -> Unit = { text -> android.widget.Toast.makeText(attachContext, text, android.widget.Toast.LENGTH_SHORT).show() }
    val openAttachment: ((MessageUi) -> Unit)? = onOpenAttachment?.let { open ->
        { m: MessageUi ->
            if (opening == null) {
                opening = m.seq
                attachScope.launch {
                    val result = open(m.seq)
                    opening = null
                    when (result) {
                        is AttachmentFiles.Opened ->
                            if (result.kind == "image") viewing = result else AttachmentIo.openWith(attachContext, result, Strings.attachmentOpenWith)
                        is AttachmentFiles.OpenFailed -> toast(result.message)
                    }
                }
            }
        }
    }
    val pickFile = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        val send = onSendAttachment
        if (uri != null && send != null) {
            attachScope.launch {
                when (val picked = withContext(Dispatchers.IO) { AttachmentIo.readPicked(attachContext, uri) }) {
                    is AttachmentIo.Picked.Ok -> send(picked.bytes, picked.name)
                    AttachmentIo.Picked.Empty -> toast(Strings.attachmentEmpty)
                    AttachmentIo.Picked.TooLarge -> toast(Strings.attachmentTooLarge)
                    AttachmentIo.Picked.Unreadable -> toast(Strings.attachmentUnreadable)
                }
            }
        }
    }
    viewing?.let { v ->
        AttachmentViewer(
            v,
            onShare = { if (!AttachmentIo.share(attachContext, v, Strings.attachmentShare)) toast(Strings.attachmentNoApp) },
            onOpenWith = { AttachmentIo.openWith(attachContext, v, Strings.attachmentOpenWith) },
            onClose = { viewing = null },
        )
    }
    var draft by rememberSaveable(room.room) { mutableStateOf("") }
    val listState = rememberLazyListState()
    val halted = room.halted
    // alert-refs-v1(ALERT-REFS-V1 §2): 플릿 알림 `#번호` → 같은 방에서 그 번호로 시작하는 가장 최근 알림으로. 없으면 토스트만.
    val alertScope = rememberCoroutineScope()
    val alertContext = LocalContext.current
    val onAlertRef: (Int, String) -> Unit = { from, id ->
        val target = AlertRefs.targetIndex(room.messages, id, from)
        if (target >= 0) alertScope.launch { listState.animateScrollToItem(target) }
        else android.widget.Toast.makeText(alertContext, Strings.alertRefMissing, android.widget.Toast.LENGTH_SHORT).show()
    }
    // 맨 아래 따라가기: 방에 들어올 때와 새 글이나 작업 상태 말풍선이 생길 때(사라질 때는 아님) 마지막 항목의 아래까지.
    // 들어올 때는 애니메이션 없이 바로(전자잉크에서 맨 위부터 훑어 내려가지 않게).
    val total = room.messages.size + room.outgoing.size + room.statuses.size
    // 셋을 따로 본다: 에이전트 답이 작업 상태 말풍선을 대신하면(글 +1 · 상태 -1) 합계는 같아도 새 글이다.
    var shownSizes by remember(room.room) { mutableStateOf<List<Int>?>(null) }
    LaunchedEffect(room.room, room.messages.size, room.outgoing.size, room.statuses.size) {
        val now = listOf(room.messages.size, room.outgoing.size, room.statuses.size)
        val before = shownSizes
        shownSizes = now
        val grew = before == null || now.indices.any { now[it] > before[it] }
        if (total > 0 && grew) listState.scrollToBottom(animated = before != null, itemCount = total)
    }
    // 바닥 지키기(iOS `followLatest`): 바닥에 있던 동안 사진 썸네일·링크 카드·선택지 카드가 늦게 그려지거나 키보드로 칸이 줄어
    // 최신 글이 밀려나면 다시 바닥으로. 손가락·↑ 키로 올려서 멈추면 끈다.
    LaunchedEffect(room.room, listState) {
        val follow = BottomFollow()
        snapshotFlow { listState.isScrollInProgress to listState.canScrollForward }.collect { (moving, canForward) ->
            if (follow.observe(moving, canForward)) listState.scrollToBottom(animated = false)
        }
    }
    // agent-choices(#620 · §6 #671 PR D): 에이전트가 `[답변 필요]` 로 명시한 번호 선택지 → 말풍선 아래 카드(open/answered). 상태는 타임라인에서 계산(저장 안 함).
    val choiceCards = remember(room.messages) { AgentChoices.cards(room.messages) }
    val canChoose = halted == null && room.joined && live
    // #690 v2: 이 세션의 미리보기 사이트 목록(받기 전·실패 = v1 폴백). 목록이 도착하면 보이는 말풍선이 링크·카드를 다시 정한다.
    val sitesFlow = remember(previews) { previews?.sites ?: MutableStateFlow(PreviewSites.FALLBACK) }
    val sites by sitesFlow.collectAsStateWithLifecycle()
    // #880 말풍선 답장(iOS `ReplyQuote`): 고른 글을 보낼 때 본문 맨 앞 인용 한 줄로 붙인다(형식 무변경). ✕ 는 답장만 취소(쓰던 글은 그대로).
    var replying by remember(room.room) { mutableStateOf<ReplyTarget?>(null) }
    val sendDraft: () -> Unit = {
        val text = draft.trim()
        onSend(replying?.let { ReplyQuote.compose(it.name, it.seq, it.original, text) } ?: text)
        replying = null
        draft = ""
    }
    // 선택지 카드의 체크·보내는 중(글 seq 별) — 카드가 화면 밖(LazyColumn 이 내림)이어도 Alt+숫자·Alt+Enter 가 같은 값을 쓰게 방에 둔다.
    val choicePicks = remember(room.room) { mutableStateMapOf<Long, List<Int>>() }
    val choiceSending = remember(room.room) { mutableStateMapOf<Long, Boolean>() }
    val sendChoice: (Long, String) -> Unit = { seq, text ->
        // 보낸 글이 타임라인에 오면 카드가 answered 로 바뀐다. 전송이 실패해 글이 안 오면 10초 뒤 다시 켠다.
        choiceSending[seq] = true
        onSend(text)
        attachScope.launch {
            delay(10_000)
            choiceSending.remove(seq)
        }
    }

    // ---- #833 하드웨어 키보드(iOS RoomView `perform` 과 같은 동작) ----
    // 작성창 커서·IME 조합은 `composerField`(TextFieldValue), 글의 정본은 `draft`(방별 저장) — 보내고 비우거나 저장값이 돌아와 글이 다르면 끝 커서로 맞춘다.
    var composerField by remember(room.room) { mutableStateOf(TextFieldValue(draft, TextRange(draft.length))) }
    fun currentComposer(): TextFieldValue = composerField.let { if (it.text == draft) it else TextFieldValue(draft, TextRange(draft.length)) }
    val setComposer: (TextFieldValue) -> Unit = { v -> composerField = v; draft = v.text }
    val clipboard = LocalClipboardManager.current
    val timelineFocus = remember { FocusRequester() }
    val composerFocus = remember { FocusRequester() }
    var composerFocused by remember { mutableStateOf(false) }
    /** 키로 옮겨 간 말풍선(대화 읽기 말풍선 단위 커서 · 선택 모드 테두리). */
    var keyCursor by remember(room.room) { mutableStateOf<Long?>(null) }
    var selectingByKey by remember(room.room) { mutableStateOf(false) }
    /** 「선택해서 복사」 창에 띄운 글. */
    var selectCopyText by remember(room.room) { mutableStateOf<String?>(null) }
    /** Enter 로 작성창에 들어온 시각(uptime ms) — 그 Enter 의 반복으로 초안을 보내지 않게(`HardwareKeys.suppressSend`). */
    var keyFocusAt by remember { mutableStateOf<Long?>(null) }
    val roomKeys = remember { HeldKeys() }
    val hasComposer = halted == null && room.joined
    // 방을 열면 타임라인에 포커스(= 대화 읽기) — 포커스가 화면 안에 있어야 키가 온다. 손가락으로는 보이는 차이가 없다.
    LaunchedEffect(Unit) { runCatching { timelineFocus.requestFocus() } }

    fun commitComposition() {
        // 한글 등 IME 조합 중인 글자를 확정한 뒤 작성창을 떠난다(#722 교훈 — 조합 글자가 버려지지 않게). 글은 이미 `draft` 에 들어 있다.
        val v = currentComposer()
        if (v.composition != null) setComposer(v.copy(composition = null))
    }
    fun selectedText(): String? =
        if (!selectingByKey) null
        else room.messages.firstOrNull { it.seq == keyCursor && !it.attachment }?.text?.let { ReplyQuote.visibleText(it) }?.takeIf { it.isNotBlank() }
    /** #880 왼쪽으로 민 말풍선에 답장: 답할 글을 정하고 작성창에 커서를 넣는다. 저장된 글이면 릴레이 seq 를 함께(v2 `#번호`). */
    fun startReply(m: MessageUi) {
        if (!hasComposer) return
        replying = ReplyTarget(name = AgentActors.displayName(m.sender), seq = m.seq.takeIf { it > 0 }, original = m.text)
        keyCursor = null
        selectingByKey = false
        runCatching { composerFocus.requestFocus() }
    }
    /** #880 인용 상자를 눌렀다: 같은 방의 그 seq 글로. 지금 불러온 대화에 없으면 안내만(iOS 와 같은 문구). */
    val onReplyQuote: (Long) -> Unit = { seq ->
        val index = room.messages.indexOfFirst { it.seq == seq }
        if (index >= 0) alertScope.launch { listState.animateScrollToItem(index) } else toast(Strings.replyTargetMissing)
    }
    fun select(step: Int) {
        // 복사할 글이 있는 말풍선만 오간다(첨부 제외).
        val rows = room.messages.filter { !it.attachment && it.text.isNotBlank() }.map { it.seq }
        val target = HardwareKeys.selectTarget(rows, keyCursor, step) ?: return
        keyCursor = target
        selectingByKey = true
        val index = room.messages.indexOfFirst { it.seq == target }
        if (index >= 0) attachScope.launch { listState.reveal(index) }
    }
    fun scrollByKey(up: Boolean) {
        selectingByKey = false
        val info = listState.layoutInfo
        val viewport = (info.viewportSize.height - info.beforeContentPadding - info.afterContentPadding).toFloat()
        val fraction = arrowStep.viewportFraction
        if (fraction != null && viewport > 0f) {
            // 작게·보통·크게: 보이는 칸의 비율만큼 픽셀로. 말풍선 커서는 비운다(손가락 스크롤과 같은 취급).
            keyCursor = null
            when (val t = HardwareKeys.pixelScroll(viewport, fraction, up, listState.canScrollBackward, listState.canScrollForward)) {
                is HardwareKeys.PixelScroll.By -> attachScope.launch { listState.animateScrollBy(t.pixels) }
                // 이미 바닥이면 제자리(예전에는 마지막 말풍선의 위로 올라가 ↓ 를 누를수록 바닥과 위를 오갔다).
                HardwareKeys.PixelScroll.Latest -> attachScope.launch { listState.scrollToBottom(animated = true) }
                null -> {}
            }
            return
        }
        // 말풍선(또는 칸 크기를 아직 모름): 한 번에 말풍선 하나 — 고른 말풍선을 칸 맨 위에 맞춘다.
        when (val t = HardwareKeys.scrollTarget(room.messages.map { it.seq }, keyCursor, up)) {
            is HardwareKeys.ScrollTarget.Row -> {
                keyCursor = t.seq
                val index = room.messages.indexOfFirst { it.seq == t.seq }
                if (index >= 0) attachScope.launch { listState.animateScrollToItem(index) }
            }
            HardwareKeys.ScrollTarget.Latest -> {
                keyCursor = null
                attachScope.launch { listState.scrollToBottom(animated = true) }
            }
            null -> {}
        }
    }
    fun pasteToComposer(): Boolean {
        if (!hasComposer) return false
        val clip = clipboard.getText()?.text
        if (clip.isNullOrBlank()) return true
        val v = currentComposer()
        val inserted = HardwareKeys.insertAt(v.text, v.selection.start, v.selection.end, clip)
        setComposer(TextFieldValue(inserted.text, TextRange(inserted.cursor)))
        keyCursor = null
        selectingByKey = false
        runCatching { composerFocus.requestFocus() }
        return true
    }
    fun performKey(action: RoomAction, event: KeyEvent): Boolean {
        when (action) {
            RoomAction.PREVIOUS_ROOM, RoomAction.NEXT_ROOM -> {
                if (composerFocused) commitComposition()
                onSwitchRoom?.invoke(if (action == RoomAction.PREVIOUS_ROOM) -1 else 1)
            }
            RoomAction.BACK_TO_LIST -> {
                if (composerFocused) commitComposition()
                onBack()
            }
            RoomAction.READ_TIMELINE -> {
                // 작성창 → 대화 읽기는 마지막 말풍선부터, 선택 모드 → 대화 읽기는 고르던 자리에서 이어 읽는다.
                if (composerFocused) commitComposition()
                if (!selectingByKey) keyCursor = null
                selectingByKey = false
                runCatching { timelineFocus.requestFocus() }
            }
            RoomAction.FOCUS_COMPOSER -> {
                if (!hasComposer) return false
                keyCursor = null
                selectingByKey = false
                keyFocusAt = event.nativeKeyEvent.eventTime
                runCatching { composerFocus.requestFocus() }
                attachScope.launch { listState.scrollToBottom(animated = true) }
            }
            RoomAction.SCROLL_UP -> scrollByKey(up = true)
            RoomAction.SCROLL_DOWN -> scrollByKey(up = false)
            RoomAction.SEND -> {
                // 빈 글·세션 확인 전에는 보내지 않지만 키는 먹는다(작성창에 줄바꿈이 들어가지 않게). 한글 조합 중이면 조합 글자까지 보낸다.
                val since = keyFocusAt?.let { (event.nativeKeyEvent.eventTime - it) / 1000.0 }
                if (!HardwareKeys.suppressSend(since) && live && draft.isNotBlank()) {
                    commitComposition()
                    sendDraft()
                }
            }
            RoomAction.NEWLINE -> {
                val v = currentComposer()
                val inserted = HardwareKeys.insertAt(v.text, v.selection.start, v.selection.end, "\n")
                setComposer(TextFieldValue(inserted.text, TextRange(inserted.cursor)))
            }
            RoomAction.START_SELECTING -> select(0)
            RoomAction.SELECT_UP -> select(-1)
            RoomAction.SELECT_DOWN -> select(1)
            RoomAction.OPEN_SELECTION -> selectedText()?.let { selectCopyText = it }
            RoomAction.COPY_SELECTION -> selectedText()?.let {
                clipboard.setText(AnnotatedString(it))
                toast(Strings.copiedToast)
            }
            RoomAction.PASTE_TO_COMPOSER -> return pasteToComposer()
        }
        return true
    }
    /** 선택지 카드 Alt+1~9 · Alt+Enter(agent-choices-v1 §3.1). 처리했으면 true. open 카드는 마지막 글의 것뿐이다. */
    fun choiceKey(event: KeyEvent): Boolean {
        val index = choiceCards.indexOfLast { it?.state == AgentChoices.State.Open }
        val card = choiceCards.getOrNull(index) ?: return false
        val m = room.messages.getOrNull(index) ?: return false
        val picked = choicePicked(card, choicePicks[m.seq].orEmpty())
        val composing = composerFocused && currentComposer().composition != null
        val keyCard = AgentChoiceKeys.Card(card.choices.items.size, picked.toSet(), enabled = canChoose && choiceSending[m.seq] != true)
        val decided = AgentChoiceKeys.decide(event.choiceInput(composing), keyCard) ?: return false
        if (event.isRepeat()) return true
        when (decided) {
            is AgentChoiceKeys.Action.Toggle -> choicePicks[m.seq] = AgentChoices.toggle(picked, decided.number, card.choices.mode)
            AgentChoiceKeys.Action.Send -> sendChoice(m.seq, AgentChoices.compose(picked, card.choices.items.map { it.label }))
        }
        return true
    }
    fun roomKey(event: KeyEvent): Boolean {
        if (event.fromSoftKeyboard()) return false
        return roomKeys.dispatch(event) {
            if (choiceKey(event)) return@dispatch true
            val press = event.hardwarePress() ?: return@dispatch false
            val mode = when {
                composerFocused -> RoomMode.COMPOSER
                selectingByKey -> RoomMode.SELECTING
                else -> RoomMode.READING
            }
            val action = HardwareKeys.roomAction(press, mode) ?: return@dispatch false
            if (event.isRepeat() && !HardwareKeys.repeats(action)) return@dispatch true
            performKey(action, event)
        }
    }
    // IME 앞(`onPreInterceptKeyBeforeSoftKeyboard`): 하드웨어 키만 온다 — 작성창 모드는 여기서만 판정한다(한글 조합 중 키가 IME 에 먹히지 않게).
    // IME 뒤(`onPreviewKeyEvent`): 작성창 밖(대화 읽기·선택 모드)만 — 작성창에 IME 가 보낸 키(화면 키보드 Enter 등)는 판정하지 않고 입력칸 기본 동작 그대로.
    // 앞에서 처리한 키(Down·Up 모두)는 뒤로 오지 않는다.
    val onRoomKeyBeforeIme: (KeyEvent) -> Boolean = { event -> roomKey(event) }
    val onRoomKeyAfterIme: (KeyEvent) -> Boolean = { event -> !composerFocused && roomKey(event) }
    selectCopyText?.let { text -> SelectCopyDialog(text, onClose = { selectCopyText = null }) }

    Scaffold(
        containerColor = Color.Transparent, contentColor = MaterialTheme.colorScheme.onBackground,
        topBar = {
            HandeTopBar(
                title = {
                    Column {
                        Text(if (ui.connecting) Strings.connecting else AgentActors.roomLabel(room.room), maxLines = 1, overflow = TextOverflow.Ellipsis)
                        if (halted != null) Text(Strings.halted, color = colors.inkDim, fontSize = 12.sp)
                    }
                },
                navigationIcon = { BackButton(onBack) },
            )
        },
        snackbarHost = { NoticeHost(ui.notice, onNoticeShown) },
    ) { pad ->
        Column(Modifier.padding(pad).fillMaxSize().imePadding().onPreInterceptKeyBeforeSoftKeyboard(onRoomKeyBeforeIme).onPreviewKeyEvent(onRoomKeyAfterIme)) {
            LazyColumn(
                Modifier.weight(1f).fillMaxWidth().alpha(if (halted != null) 0.6f else 1f).focusRequester(timelineFocus).focusable(),
                state = listState, contentPadding = PaddingValues(12.dp),
            ) {
                itemsIndexed(room.messages, key = { _, m -> "${m.sender}-${m.seq}" }) { i, m ->
                    val card = choiceCards.getOrNull(i)
                    val onAttachment = if (m.attachment) openAttachment?.let { open -> { open(m) } } else null
                    // #698 C2: 사진 첨부는 말풍선에 썸네일(보이는 행만 받아 디코드, 메모리 LRU 만).
                    val thumb = if (m.attachment && onAttachmentPreview != null && onOpenAttachment != null) {
                        ThumbSource("${room.room}/${m.seq}", preview = { onAttachmentPreview(m.seq) }, open = { onOpenAttachment(m.seq) })
                    } else null
                    // #833 선택 모드: 키로 고른 말풍선 행에 점선 테두리(자리를 차지하지 않게 바깥에 그린다).
                    Box(Modifier.keySelectionOutline(selectingByKey && keyCursor == m.seq, colors.focus)) {
                    // #880: 말풍선을 왼쪽으로 밀면 답장(선택지 카드는 밀리지 않는다).
                    val row: @Composable () -> Unit = {
                        SwipeToReply(enabled = hasComposer, onReply = { startReply(m) }) {
                            MessageRow(
                                m, previews, sites, opening = opening == m.seq, onAttachment = onAttachment, thumb = thumb,
                                onReplyQuote = onReplyQuote,
                            ) { id -> onAlertRef(i, id) }
                        }
                    }
                    if (card == null) {
                        row()
                    } else {
                        Column(Modifier.fillMaxWidth()) {
                            row()
                            AgentChoicesCard(
                                m, card, enabled = canChoose && choiceSending[m.seq] != true,
                                picked = choicePicked(card, choicePicks[m.seq].orEmpty()), onPicked = { choicePicks[m.seq] = it },
                                onSend = { text -> sendChoice(m.seq, text) },
                            )
                        }
                    }
                    }
                }
                // #837: 아직 확정되지 않은 내 글(누른 순서) — 받으면 위의 이력 행이 되고 여기서 빠진다.
                items(room.outgoing, key = { "out:${it.id}" }) { o -> OutgoingRow(o, onRetrySend = if (live) onRetrySend else null) }
                // status-v1(#560): 보낸이별 임시 말풍선 하나 — 키가 보낸이라 제자리에서 본문만 바뀐다.
                items(room.statuses, key = { "status:${it.sender}" }) { s -> StatusRow(s) }
            }
            if (halted != null) {
                HaltedBox(halted)
            } else if (!room.joined) {
                Text(Strings.notJoined, Modifier.padding(12.dp), color = colors.inkDim)
            } else {
                replying?.let { target -> ReplyBanner(target, onCancel = { replying = null }) }
                Composer(
                    currentComposer(), onValue = setComposer, onSend = sendDraft,
                    onAttach = if (onSendAttachment != null && live) ({ pickFile.launch(arrayOf("*/*")) }) else null,
                    enabled = live,
                    fieldModifier = Modifier.focusRequester(composerFocus).onFocusChanged { state ->
                        composerFocused = state.hasFocus
                        if (state.hasFocus) selectingByKey = false
                    },
                )
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

/** 입력창(알약, 면+선) + 보내기(44dp 주황 원 「↑」, 비면 35%). 화면에서 큰 주황 면은 내 말풍선과 이 버튼뿐. `enabled` 가 거짓이면(#766 B 세션 확인 전) 글은 쓸 수 있고 보내기만 꺼진다. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun Composer(
    value: TextFieldValue, onValue: (TextFieldValue) -> Unit, onSend: () -> Unit, onAttach: (() -> Unit)? = null, enabled: Boolean = true,
    /** #833: 포커스(작성창 모드)·포커스 요청을 대화방이 쥔다. */
    fieldModifier: Modifier = Modifier,
) {
    val colors = LocalHandeColors.current
    val canSend = enabled && value.text.isNotBlank()
    Row(Modifier.padding(horizontal = 12.dp, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.Bottom) {
        // #366 C: 첨부 보내기(시스템 파일 선택) — 면+선 44dp 원(주황 면은 보내기 버튼만).
        if (onAttach != null) {
            Box(
                Modifier
                    .padding(bottom = 6.dp)
                    .size(44.dp)
                    .clip(CircleShape)
                    .background(colors.surface)
                    .border(colors.lineWidth, colors.stroke, CircleShape)
                    .clickable(role = Role.Button, onClick = onAttach)
                    .semantics { contentDescription = Strings.attachButton },
                contentAlignment = Alignment.Center,
            ) { Icon(HandeIcons.add(colors.ink), contentDescription = null, Modifier.size(20.dp), tint = Color.Unspecified) }
        }
        OutlinedTextField(
            value, onValue, Modifier.weight(1f).then(fieldModifier),
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

/** #880 답할 글: 보낸 이 이름 · 릴레이 seq(없으면 null) · 원문(인용 요약은 보낼 때 `ReplyQuote.compose` 가 만든다). */
private data class ReplyTarget(val name: String, val seq: Long?, val original: String)

/**
 * #880 말풍선 「밀어서 답장」(판정 `SwipeReply` — iOS 와 같은 수치): 왼쪽으로 밀면 말풍선이 손가락을 따라가고 오른쪽 끝에 답장 표시가 드러난다.
 * 문턱을 넘으면 진동 한 번, 그 상태로 손을 떼면 [onReply]. 세로·오른쪽·비스듬한 끌기는 건드리지 않아 타임라인 스크롤이 그대로 받는다.
 * 답장 끌기로 정해진 뒤에만 포인터를 먹는다(그 전의 누르기·링크는 종전 그대로). 놓으면 애니메이션 없이 제자리(전자잉크).
 * 말풍선 안에서 옆으로 스크롤되는 블록(#887 넘치는 코드 블록·표) 위에서 시작한 가로 끌기는 그 블록의 스크롤이다 — 답장은 말풍선의 다른 자리를 밀면 된다.
 */
@Composable
private fun SwipeToReply(enabled: Boolean, onReply: () -> Unit, content: @Composable () -> Unit) {
    if (!enabled) {
        content()
        return
    }
    val colors = LocalHandeColors.current
    val haptic = LocalHapticFeedback.current
    val latestOnReply by rememberUpdatedState(onReply)
    var offsetDp by remember { mutableStateOf(0f) }
    var armed by remember { mutableStateOf(false) }
    Box(
        Modifier.fillMaxWidth().pointerInput(Unit) {
            awaitEachGesture {
                val down = awaitFirstDown(requireUnconsumed = false)
                var axis: SwipeReply.Axis? = null
                var dx = 0.0
                var dy = 0.0
                try {
                    while (true) {
                        val event = awaitPointerEvent()
                        val change = event.changes.firstOrNull { it.id == down.id } ?: break
                        val moved = change.position - down.position
                        dx = moved.x.toDp().value.toDouble()
                        dy = moved.y.toDp().value.toDouble()
                        if (!change.pressed) break
                        // #887: 말풍선 안의 옆으로 스크롤되는 블록(넘치는 코드 블록·표)이 이 끌기를 먼저 받았으면 답장 끌기로 삼지 않는다 — 놓아준다.
                        if (axis == null && change.isConsumed) break
                        if (axis == null) {
                            axis = SwipeReply.axis(dx, dy)
                            // 세로 스크롤·오른쪽 끌기: 이 끌기는 놓아준다(먹지 않으니 타임라인이 받는다).
                            if (axis == SwipeReply.Axis.IGNORE) break
                        }
                        if (axis == SwipeReply.Axis.REPLY) {
                            change.consume()
                            offsetDp = SwipeReply.offset(dx).toFloat()
                            val now = SwipeReply.shouldReply(dx, dy)
                            if (now && !armed) haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                            armed = now
                        }
                    }
                    if (axis == SwipeReply.Axis.REPLY && SwipeReply.shouldReply(dx, dy)) latestOnReply()
                } finally {
                    offsetDp = 0f
                    armed = false
                }
            }
        },
    ) {
        Box(Modifier.fillMaxWidth().offset { IntOffset(offsetDp.dp.roundToPx(), 0) }) { content() }
        if (offsetDp < 0f) {
            Text(
                "↩", Modifier.align(Alignment.CenterEnd).padding(end = 12.dp),
                color = if (armed) colors.ember else colors.inkDim, fontSize = 20.sp, fontWeight = if (armed) FontWeight.Bold else FontWeight.Normal,
            )
        }
    }
}

/** #880 작성창 위 「OO에게 답장 · 원문 요약 ✕」 띠(iOS `replyBanner`). ✕ 는 답장만 취소한다(쓰던 글은 그대로). */
@Composable
private fun ReplyBanner(target: ReplyTarget, onCancel: () -> Unit) {
    val colors = LocalHandeColors.current
    val snippet = remember(target.original) { ReplyQuote.snippet(target.original) }
    Row(
        Modifier.fillMaxWidth().padding(start = 18.dp, end = 10.dp, top = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically,
    ) {
        Text("↩", color = colors.ember, fontSize = 15.sp)
        Column(Modifier.weight(1f)) {
            Text(Strings.replyingTo(target.name), color = colors.ink, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(snippet, color = colors.inkDim, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Box(
            Modifier
                .size(40.dp)
                .clip(CircleShape)
                .clickable(role = Role.Button, onClick = onCancel)
                .semantics { contentDescription = Strings.replyCancel },
            contentAlignment = Alignment.Center,
        ) { Text("✕", color = colors.inkDim, fontSize = 16.sp) }
    }
}

/** #880 답장 글의 인용 상자(iOS `ReplyQuoteBox`): 왼쪽 세로줄 + 이름 + 원문 요약(3줄). 번호(seq)가 있으면 눌러서 원래 글로. */
@Composable
private fun ReplyQuoteBox(parsed: ReplyQuote.Parsed, tint: Color, onOpen: (() -> Unit)?) {
    Row(
        Modifier
            .height(IntrinsicSize.Min)
            .then(if (onOpen != null) Modifier.clickable(role = Role.Button, onClickLabel = Strings.replyQuoteOpenHint, onClick = onOpen) else Modifier),
        horizontalArrangement = Arrangement.spacedBy(7.dp),
    ) {
        Box(Modifier.width(3.dp).fillMaxHeight().clip(RoundedCornerShape(1.5.dp)).background(tint))
        Column {
            parsed.name?.let { Text(it, color = tint, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis) }
            Text(parsed.snippet, color = tint, fontSize = 13.sp, lineHeight = 18.sp, maxLines = 3, overflow = TextOverflow.Ellipsis)
        }
    }
}

/**
 * 말풍선: 남 = 면+선(꼬리 왼쪽 아래 6) · 나 = 불(꼬리 오른쪽 아래 6) · 에이전트 = 파랑 fill 10% + stroke 35%(낮불: 흰 면 + 파랑 점선 1.5).
 * 보낸 이 라벨 = 좌석 점 + 이름(에이전트는 「공명 · 불지기」 파랑). 너비는 82% 까지(에이전트의 서식 글은 88%). 첨부는 본문의 자리 표시 글 그대로(C 단계).
 */
@Composable
private fun MessageRow(
    m: MessageUi,
    previews: LinkPreviews? = null,
    sites: PreviewSites.Registry = PreviewSites.FALLBACK,
    opening: Boolean = false,
    onAttachment: (() -> Unit)? = null,
    thumb: ThumbSource? = null,
    /** #880 인용 상자를 누르면 그 seq 글로. */
    onReplyQuote: ((Long) -> Unit)? = null,
    onAlertRef: ((String) -> Unit)? = null,
) {
    val colors = LocalHandeColors.current
    val agent = !m.mine && AgentActors.isAgentDevice(m.sender)
    // #880 답장 글(iOS 와 같이 사람 말풍선만 — 내 글 포함): 인용 상자 + 내 글. 링크·참조·미리보기는 내 글에서만 찾는다.
    val reply = remember(m.text, agent, m.attachment) { if (!agent && !m.attachment) ReplyQuote.parse(m.text) else null }
    // #887 3단계: 에이전트 답 끝의 스킬 줄(`📘 a · b`)은 본문에서 떼어 말풍선 아래 칩으로 그린다(웹·iOS 와 같은 규칙 — `AgentSkills.split`).
    // 규칙에 안 맞으면 글 그대로(칩 없음). 선택지 카드·답장 인용·복사는 원문(m.text) 기준 그대로다.
    val skillSplit = remember(m.text, agent, m.attachment) { if (agent && !m.attachment) AgentSkills.split(m.text) else null }
    val shown = reply?.text ?: skillSplit?.body ?: m.text
    // #887 1단계: 에이전트 글이 서식 글(제목·목록·코드·굵게 …)이면 블록으로 그린다. 판정·나누기는 글마다 한 번(`remember`) — 서식이 없거나
    // 상한(`AgentMarkdown.MAX_SOURCE`)을 넘는 글, 사람 글, 첨부 자리 글은 null 이라 아래 평문 경로 그대로다. 선택지 카드·복사는 원문(m.text) 기준 그대로.
    val markdown = remember(shown, agent, m.attachment) { if (agent && !m.attachment) AgentMarkdown.blocksIfMarkdown(shown) else null }
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
        // #683 · #690 v2: 사람 말풍선의 허용 호스트(사이트 목록 hosts 합집합, 폴백 = x.com 계열) https 주소만 누를 수 있게(웹·iOS 와 같은 규칙).
        // 에이전트 말풍선은 http·https 주소면 어떤 호스트든 링크(오너 2026-11-16, `TextLinks.agentLinks`).
        // 말풍선 글은 remember 로 캐시된다 — 그 안 클릭은 늘 최신 콜백(최신 목록·index)을 부르게.
        val latestOnAlertRef by rememberUpdatedState(onAlertRef)
        val body = remember(shown, m.text, agent, sites, opening, onAttachment != null, markdown != null) {
            // 서식 글은 `AgentMarkdownBody` 가 블록마다 따로 그린다 — 평문용 글은 만들지 않는다.
            if (markdown != null) AnnotatedString("")
            // #366 C: 첨부 말풍선 = 자리 표시 + 「눌러서 열기」/「여는 중…」 한 줄(링크·참조는 찾지 않는다).
            else if (m.attachment) AnnotatedString(if (onAttachment == null) m.text else m.text + "\n" + (if (opening) Strings.attachmentOpening else Strings.attachmentTapHint))
            else buildAnnotatedString {
                append(shown)
                val found = if (agent) TextLinks.agentLinks(shown) else sites.links(shown)
                for (link in found) {
                    addLink(LinkAnnotation.Url(link.url, TextLinkStyles(SpanStyle(textDecoration = TextDecoration.Underline))), link.start, link.end)
                }
                // alert-refs-v1: 플릿 알림 봇 글의 참조 `#번호` → 원래 알림으로 이동(허용 링크와 겹치면 링크가 이긴다).
                if (onAlertRef != null && AlertRefs.isFleetDevice(m.sender)) {
                    for (ref in AlertRefs.parse(shown).refs) {
                        if (found.any { it.start < ref.end && ref.start < it.end }) continue
                        addLink(
                            LinkAnnotation.Clickable("alert:${ref.id}", TextLinkStyles(SpanStyle(textDecoration = TextDecoration.Underline))) { latestOnAlertRef?.invoke(ref.id) },
                            ref.start, ref.end,
                        )
                    }
                }
            }
        }
        // 서식 글 말풍선은 조금 더 넓게(웹 `.bubble:has(.body.md)` 의 88% 와 같은 값) — 표·코드 블록이 한 열이라도 더 보이게.
        val bubbleModifier = Modifier
            .fillMaxWidth(if (markdown != null) 0.88f else 0.82f)
            .wrapContentWidth(if (m.mine) Alignment.End else Alignment.Start)
            .clip(shape)
            .then(fill)
            .then(if (onAttachment != null) Modifier.clickable(enabled = !opening, role = Role.Button, onClick = onAttachment) else Modifier)
            .padding(horizontal = 14.dp, vertical = 11.dp)
        val textColor = if (m.mine) colors.onEmber else colors.ink
        val bubble: @Composable () -> Unit = {
            if (markdown != null) {
                AgentMarkdownBody(markdown, bubbleModifier, textColor)
            } else if (reply == null) {
                Text(body, bubbleModifier, color = textColor, style = MaterialTheme.typography.bodyLarge)
            } else {
                Column(bubbleModifier, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    val openQuote: (() -> Unit)? = reply.seq?.let { seq -> onReplyQuote?.let { jump -> { jump(seq) } } }
                    ReplyQuoteBox(reply, tint = if (m.mine) colors.onEmber.copy(alpha = 0.8f) else colors.inkDim, onOpen = openQuote)
                    Text(body, color = textColor, style = MaterialTheme.typography.bodyLarge)
                }
            }
        }
        // #698 C2: 사진으로 판별된 첨부는 자리 표시 글 대신 썸네일(누르면 같은 뷰어). 사진이 아니거나 받지 못하면 글 그대로.
        if (thumb != null) AttachmentThumbnail(thumb, shape, opening, onAttachment, fallback = bubble) else bubble()
        // #887 3단계: 답이 쓴 스킬 — 말풍선 아래 칩 줄(서식 글 말풍선과 같은 최대 너비 안에서 여러 줄로 넘어간다).
        val skills = skillSplit?.skills.orEmpty()
        if (skills.isNotEmpty()) AgentSkillChips(skills, Modifier.padding(start = 4.dp, top = 6.dp).fillMaxWidth(0.88f))
        // #683 2단계 · #690 v2: 사람 말풍선(내 글 포함, 첨부 자리 글 제외)의 카드 대상(v2 = preview 사이트의 첫 링크, 폴백 = 첫 x.com 글 링크)
        // → 릴레이 미리보기 카드. 없거나 실패면 아무것도 그리지 않는다.
        if (!agent && !m.attachment && previews != null) {
            val target = remember(shown, sites) { sites.target(shown) }
            if (target != null) LinkPreviewCard(target, previews, siteName = remember(target, sites) { sites.siteOf(target)?.name.orEmpty() })
        }
    }
}

/**
 * 보내는 글 말풍선(#837, iOS 보내는 글 줄과 같은 말): 내 말풍선 모양 그대로 「보내는 중…」(밤 75% — 낮불은 불투명), 실패하면 면+주의 선 +
 * 「전송 안 됨」과 「다시 보내기」. 첨부의 진행 표시는 이 이슈 밖이다.
 */
@Composable
private fun OutgoingRow(o: OutgoingUi, onRetrySend: ((Long) -> Unit)?) {
    val colors = LocalHandeColors.current
    val shape = RoundedCornerShape(18.dp, 18.dp, 6.dp, 18.dp)
    Column(Modifier.fillMaxWidth().padding(vertical = 3.dp), horizontalAlignment = Alignment.End) {
        val fill = if (o.failed) Modifier.background(colors.surface).border(1.5.dp, colors.warn, shape)
        else Modifier.background(colors.ember.copy(alpha = if (colors.isDay) 1f else 0.75f))
        Text(
            o.text,
            Modifier
                .fillMaxWidth(0.82f)
                .wrapContentWidth(Alignment.End)
                .clip(shape)
                .then(fill)
                .padding(horizontal = 14.dp, vertical = 11.dp),
            color = if (o.failed) colors.ink else colors.onEmber,
            style = MaterialTheme.typography.bodyLarge,
        )
        Row(Modifier.padding(end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(
                if (o.failed) Strings.outgoingFailed else Strings.outgoingSending,
                style = MaterialTheme.typography.bodySmall,
                color = if (o.failed) colors.warnText else colors.inkDim,
            )
            if (o.failed && onRetrySend != null) {
                TextButton(onClick = { onRetrySend(o.id) }) { Text(Strings.outgoingRetry, color = colors.warnText) }
            }
        }
    }
}

/**
 * 말풍선 사진 썸네일(#698 C2): 이 행이 그려질 때만(LazyColumn 의 보이는 항목) 이력에서 시도 여부·w/h 힌트를 읽고, 사진일 만하면 바이트를
 * 얻어 긴 변 360dp × density 로 디코드한다(`AttachmentThumbs` — 메모리 LRU 만, 디스크 없음). 힌트가 있으면 받기 전에 자리를 최종 크기로
 * 잡는다(#647). 사진이 아니거나 그릴 수 없거나 받지 못하면 [fallback](자리 표시 말풍선). 누르면 [onClick] — 기존 전체 화면 뷰어.
 */
@Composable
private fun AttachmentThumbnail(thumb: ThumbSource, shape: Shape, opening: Boolean, onClick: (() -> Unit)?, fallback: @Composable () -> Unit) {
    val colors = LocalHandeColors.current
    val density = LocalDensity.current.density
    var preview by remember(thumb.key) { mutableStateOf(AttachmentThumbs.cachedPreview(thumb.key)) }
    var bitmap by remember(thumb.key) { mutableStateOf(AttachmentThumbs.cached(thumb.key)) }
    var failed by remember(thumb.key) { mutableStateOf(AttachmentThumbs.knownNotImage(thumb.key)) }
    LaunchedEffect(thumb.key) {
        if (bitmap != null || failed) return@LaunchedEffect
        val p = AttachmentThumbs.preview(thumb)
        preview = p
        if (p == null || !p.candidate) {
            failed = true
            return@LaunchedEffect
        }
        val loaded = AttachmentThumbs.load(thumb, ThumbnailSizing.targetLongSidePx(density))
        if (loaded == null) failed = true else bitmap = loaded
    }
    val b = bitmap
    val p = preview
    val dims = when {
        failed -> null
        b != null -> ThumbnailSizing.box(b.width, b.height)
        p != null && p.candidate && p.w != null && p.h != null -> ThumbnailSizing.box(p.w, p.h)
        else -> null
    }
    if (dims == null) {
        fallback()
        return
    }
    val image = remember(b) { b?.asImageBitmap() }
    Box(
        Modifier
            .size(dims.first.dp, dims.second.dp)
            .clip(shape)
            .background(colors.surface)
            .border(colors.lineWidth, colors.stroke, shape)
            .then(if (onClick != null) Modifier.clickable(enabled = !opening, role = Role.Button, onClick = onClick) else Modifier)
            .semantics { contentDescription = Strings.attachmentPhoto },
        contentAlignment = Alignment.Center,
    ) {
        if (image != null) Image(image, contentDescription = null, Modifier.fillMaxSize().alpha(if (opening) 0.6f else 1f), contentScale = ContentScale.Fit)
    }
}

/**
 * 첨부 이미지 뷰어(#366 C): 검은 바탕 전체 화면 Dialog — 이미지(긴 변 ≤ 2048px 로 줄여 디코딩, 비율 유지) + 아래 「공유」·「다른 앱으로 열기」·「닫기」.
 * 디코딩은 화면 스레드 밖에서. 디코딩할 수 없으면(형식·손상) 다른 앱으로 넘기고 닫는다. 바이트는 이 화면 상태에만 있다(이력 저장 안 함).
 */
@Composable
private fun AttachmentViewer(opened: AttachmentFiles.Opened, onShare: () -> Unit, onOpenWith: () -> Unit, onClose: () -> Unit) {
    val decoded by produceState<Any?>(initialValue = Unit, opened) {
        value = withContext(Dispatchers.Default) { AttachmentIo.decodeImage(opened.bytes) }
    }
    LaunchedEffect(decoded) { if (decoded == null) { onOpenWith(); onClose() } }
    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Column(Modifier.fillMaxSize().background(Color.Black)) {
            Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                val bitmap = decoded as? androidx.compose.ui.graphics.ImageBitmap
                if (bitmap != null) {
                    Image(bitmap, contentDescription = opened.name, Modifier.fillMaxSize(), contentScale = ContentScale.Fit)
                } else {
                    Text(Strings.attachmentOpening, color = Color.White)
                }
            }
            Row(Modifier.fillMaxWidth().padding(12.dp), horizontalArrangement = Arrangement.SpaceEvenly) {
                TextButton(onClick = onShare) { Text(Strings.attachmentShare, color = Color.White) }
                TextButton(onClick = onOpenWith) { Text(Strings.attachmentOpenWith, color = Color.White) }
                TextButton(onClick = onClose) { Text(Strings.close, color = Color.White) }
            }
        }
    }
}

/**
 * 「선택해서 복사」 창(#833, iOS `SelectableTextSheet` 의 Android 판): 선택 모드 Enter 로 연다. 글 칸은 읽기 전용 입력칸이라 하드웨어 키보드로
 * 커서를 옮기고 Shift+방향키로 블록을 잡을 수 있다(글은 바뀌지 않는다) — Ctrl+C = 잡은 블록 복사(「복사했어요」) · 「전체 복사」 = 글 전체 복사 후 닫기 ·
 * Esc(시스템 「뒤로」)·「닫기」 = 닫기(대화방 선택 모드는 그대로). 받은 글은 링크로 만들지 않는다.
 */
@Composable
private fun SelectCopyDialog(text: String, onClose: () -> Unit) {
    val colors = LocalHandeColors.current
    val clipboard = LocalClipboardManager.current
    val context = LocalContext.current
    val focus = remember { FocusRequester() }
    var field by remember(text) { mutableStateOf(TextFieldValue(text, TextRange(0))) }
    val copied: () -> Unit = { android.widget.Toast.makeText(context, Strings.copiedToast, android.widget.Toast.LENGTH_SHORT).show() }
    LaunchedEffect(Unit) { runCatching { focus.requestFocus() } }
    Dialog(onDismissRequest = onClose) {
        val shape = RoundedCornerShape(28.dp)
        Column(
            Modifier.fillMaxWidth().clip(shape).background(MaterialTheme.colorScheme.surfaceContainerHigh).padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(Strings.messageSelectCopy, color = colors.ink, fontSize = 20.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.semantics { heading() })
            OutlinedTextField(
                field,
                onValueChange = { if (it.text == text) field = it }, // 읽기 전용 — 커서·선택만 바뀐다
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(max = 360.dp)
                    .focusRequester(focus)
                    .onPreviewKeyEvent { event ->
                        // Ctrl+C: 잡은 블록을 복사하고 알린다(입력칸 기본 복사도 같은 글이지만 알림이 없다). 잡은 것이 없으면 그대로 둔다.
                        val sel = field.selection
                        val ctrlC = event.type == KeyEventType.KeyDown && event.key == Key.C && event.isCtrlPressed &&
                            !event.isAltPressed && !event.isMetaPressed && !event.isShiftPressed
                        if (ctrlC && !sel.collapsed) {
                            clipboard.setText(AnnotatedString(text.substring(sel.min.coerceIn(0, text.length), sel.max.coerceIn(0, text.length))))
                            copied()
                            true
                        } else {
                            false
                        }
                    },
                readOnly = true,
                textStyle = MaterialTheme.typography.bodyLarge,
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = colors.focus, unfocusedBorderColor = colors.stroke,
                    focusedContainerColor = colors.surface, unfocusedContainerColor = colors.surface,
                    cursorColor = colors.ember, focusedTextColor = colors.ink, unfocusedTextColor = colors.ink,
                ),
            )
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                TextButton(onClick = onClose) { Text(Strings.close) }
                TextButton(onClick = { clipboard.setText(AnnotatedString(text)); copied(); onClose() }) { Text(Strings.messageCopyAll) }
            }
        }
    }
}

/**
 * 링크 미리보기 카드(#683 2단계 · #690 v2): 작은 사이트 이름(응답 `site`, 비면 사이트 목록의 이름) · 제목 1줄 · 본문 최대 4줄 · 이미지(있으면, 최대 높이 200dp, 비율 유지).
 * 화면에 보일 때(`LaunchedEffect` — LazyColumn 은 보이는 항목만 그린다) 한 번 묻고, 결과는 `LinkPreviews` 메모리 캐시. 카드 탭 = 말풍선의 원래 링크 열기.
 * 면+선 카드(남 말풍선과 같은 면) — 내 말풍선 아래에서도 같은 모양(주황 면은 말풍선·보내기 버튼만).
 */
@Composable
private fun LinkPreviewCard(link: String, previews: LinkPreviews, siteName: String = "") {
    val colors = LocalHandeColors.current
    val uriHandler = LocalUriHandler.current
    var card by remember(link) { mutableStateOf(previews.cachedCard(link)) }
    LaunchedEffect(link) { if (card == null) card = previews.card(link) }
    val c = card ?: return
    val imagePath = c.image
    var image by remember(imagePath) { mutableStateOf(imagePath?.let { previews.cachedImage(it) }) }
    LaunchedEffect(imagePath) { if (imagePath != null && image == null) image = previews.image(imagePath) }
    val shape = RoundedCornerShape(14.dp)
    Column(
        Modifier
            .fillMaxWidth(0.82f)
            .padding(top = 6.dp)
            .clip(shape)
            .background(colors.surface)
            .border(colors.lineWidth, colors.stroke, shape)
            .clickable(role = Role.Button, onClickLabel = Strings.linkPreviewOpen) { runCatching { uriHandler.openUri(link) } },
    ) {
        Column(Modifier.padding(horizontal = 12.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            val site = c.site.ifEmpty { siteName }
            if (site.isNotEmpty()) {
                Text(site, color = colors.inkDim, style = MaterialTheme.typography.labelSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            if (c.title.isNotEmpty()) {
                Text(c.title, color = colors.ink, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            if (c.description.isNotEmpty()) {
                Text(c.description, color = colors.inkDim, style = MaterialTheme.typography.bodySmall, maxLines = 4, overflow = TextOverflow.Ellipsis)
            }
        }
        image?.let { bitmap ->
            Image(
                bitmap = bitmap,
                contentDescription = null,
                modifier = Modifier.fillMaxWidth().heightIn(max = 200.dp),
                contentScale = ContentScale.Fit,
            )
        }
    }
}

/** 카드에 보일 체크: ONE 카드(「하나만」)는 옛 복수 선택 기억을 버린다 — 카드 탭과 Alt+숫자(#833)가 같은 값을 쓴다. */
private fun choicePicked(card: AgentChoices.Card, remembered: List<Int>): List<Int> =
    if (card.choices.mode == AgentChoices.Mode.ONE && remembered.size > 1) emptyList() else remembered

/** 선택지 카드 행의 라벨 줄 수 상한(규격 §3). 웹·iOS 는 3줄, Android 는 6줄. */
private const val CHOICE_LABEL_MAX_LINES = 6

/**
 * 에이전트 선택지 카드(agent-choices-v1 #620 §3 · 복수 선택 #624): 행 = 체크 상자(둥근 사각) + 번호 + 라벨(최대 3줄) + 「권장」 알약.
 * 행을 누르면 그 행 체크를 토글하고(여러 개 가능), 하나라도 체크돼 있을 때만 [보내기] → 평소 전송 경로(`onSend`)로
 * `AgentChoices.compose` 결과(줄마다 `N. 라벨` — 번호보다 내용이 중요해서, 답 판정 B 로 같은 번호가 된다)를 보낸다. 보내는 동안 카드는 꺼지고,
 * 보낸 글이 타임라인에 오면 상태가 answered 로 바뀌어 한 줄 「✓ 1, 3번 선택 — 라벨1 · 라벨3」 이 된다. 전송이 실패해 글이 안 오면 10초 뒤 다시 켠다.
 * `enabled = false`(꺼진 자리·참여 전)면 고를 수도 보낼 수도 없다.
 * 「하나만」 명시 블록(mode ONE, 규격 §5.1 · #671 PR B)은 라디오: 둥근 테두리 + 가운데 점, 역할 RadioButton(묶음 selectableGroup),
 * 행 탭은 `AgentChoices.toggle` 로 바꿔 고르기라 [보내기] 는 `N. 라벨` 한 줄이다. MANY·v1 은 그대로.
 */
@Composable
private fun AgentChoicesCard(
    m: MessageUi, card: AgentChoices.Card, enabled: Boolean,
    /** 체크(대화방이 글 seq 별로 들고 있다 — §3.1 단축키 Alt+숫자와 공유, #833). 보내는 중이면 대화방이 `enabled` 를 끈다. */
    picked: List<Int>, onPicked: (List<Int>) -> Unit,
    onSend: (String) -> Unit,
) {
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
    val mode = choices.mode
    val one = mode == AgentChoices.Mode.ONE
    val active = enabled
    val shape = RoundedCornerShape(14.dp)
    Column(
        Modifier
            .fillMaxWidth(0.82f)
            .padding(top = 6.dp)
            .clip(shape)
            .background(if (colors.isDay) colors.surface else colors.agent.copy(alpha = 0.06f))
            .border(colors.lineWidth, if (colors.isDay) colors.agent else colors.agent.copy(alpha = 0.35f), shape)
            .alpha(if (active) 1f else 0.6f)
            .then(if (one) Modifier.selectableGroup() else Modifier)
            .padding(vertical = 4.dp),
    ) {
        for (item in choices.items) {
            val on = item.number in picked
            val recommended = item.number in choices.recommendedNumbers // 권장 번호 모두(§1.7 — 접두 `(권장)` 여럿)
            Row(
                Modifier
                    .fillMaxWidth()
                    .clickable(enabled = active, role = if (one) Role.RadioButton else Role.Checkbox) {
                        onPicked(AgentChoices.toggle(picked, item.number, mode))
                    }
                    .semantics {
                        contentDescription = Strings.choiceRowLabel(item.number, item.label, recommended)
                        if (one) {
                            selected = on
                        } else {
                            toggleableState = if (on) ToggleableState.On else ToggleableState.Off
                        }
                    }
                    .padding(horizontal = 12.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalAlignment = Alignment.Top,
            ) {
                if (one) {
                    Box(
                        Modifier
                            .padding(top = 1.dp)
                            .size(20.dp)
                            .clip(CircleShape)
                            .border(1.5.dp, if (on) colors.ember else colors.inkDim, CircleShape),
                        contentAlignment = Alignment.Center,
                    ) { if (on) Box(Modifier.size(10.dp).clip(CircleShape).background(colors.ember)) }
                } else {
                    Box(
                        Modifier
                            .padding(top = 1.dp)
                            .size(20.dp)
                            .clip(RoundedCornerShape(4.dp))
                            .then(if (on) Modifier.background(colors.ember) else Modifier.border(1.5.dp, colors.inkDim, RoundedCornerShape(4.dp))),
                        contentAlignment = Alignment.Center,
                    ) { if (on) Text("✓", color = colors.onEmber, fontSize = fixedSp(12.dp), fontWeight = FontWeight.Bold) } // 고정 20dp 상자 안의 표시 — 글자 크기 설정을 따라 커지지 않게
                }
                Text("${item.number}", color = colors.agentText, fontWeight = FontWeight.SemiBold, style = MaterialTheme.typography.bodyLarge)
                // 라벨은 최대 6줄(규격 §3 — Android 만 6줄, 오너 2026-11-25): 폭이 좁고 글자를 키운 기기(674dp · 배율 1.3)에서는 한 줄이 20자 안팎이라
                // 3줄이면 승인 대상(PR 번호·head)이 든 긴 선택지의 뒤가 잘린다. 보내는 글은 라벨 전체 그대로다.
                Text(item.label, Modifier.weight(1f), color = colors.ink, style = MaterialTheme.typography.bodyLarge, maxLines = CHOICE_LABEL_MAX_LINES, overflow = TextOverflow.Ellipsis)
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
                        if (picked.isNotEmpty()) onSend(AgentChoices.compose(picked, choices.items.map { it.label }))
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
    relayHost: String? = null, onDevices: (() -> Unit)? = null, onSiblingRescan: ((Boolean) -> Unit)? = null,
    /** #833 「↑/↓ 키 이동」(하드웨어 키보드 대화 읽기). */
    arrowStep: HardwareKeys.ArrowScrollStep = HardwareKeys.ArrowScrollStep.STANDARD, onArrowStep: (HardwareKeys.ArrowScrollStep) -> Unit = {},
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
                    // #833 · iOS #768: 하드웨어 키보드로 대화를 읽을 때 ↑/↓ 한 번의 이동(기본 보통 = 보이는 칸의 1/3, 말풍선 = 예전 방식).
                    Text(Strings.arrowStepLabel, Modifier.padding(start = 4.dp, top = 8.dp), color = colors.ink, fontSize = 17.sp)
                    val steps = HardwareKeys.ArrowScrollStep.entries
                    HandeSegmented(steps.map { Strings.arrowStepChip(it) }, selected = steps.indexOf(arrowStep)) { i -> onArrowStep(steps[i]) }
                    Text(Strings.arrowStepHint(arrowStep), Modifier.padding(horizontal = 4.dp), color = colors.inkDim, fontSize = 13.sp, lineHeight = 19.sp)
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
                        // #616 「빠진 방 다시 찾기」(기본 켜짐): 내 다른 기기가 빠진 방을 최소 6시간마다 다시 찾아 초대한다(일부러 내보낸 방은 건너뜀).
                        if (onSiblingRescan != null) {
                            SectionRow(onClick = { onSiblingRescan(!ui.siblingRescan) }) {
                                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                                    Text(Strings.siblingRescanTitle, color = colors.ink, fontSize = 17.sp)
                                    Text(Strings.siblingRescanHint, color = colors.inkDim, fontSize = 13.sp, lineHeight = 19.sp)
                                }
                                Switch(
                                    checked = ui.siblingRescan, onCheckedChange = onSiblingRescan,
                                    colors = SwitchDefaults.colors(checkedTrackColor = colors.ember),
                                    modifier = Modifier.semantics { contentDescription = Strings.siblingRescanTitle },
                                )
                            }
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

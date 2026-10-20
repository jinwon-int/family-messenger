// 화면 3 + 1(#338 B1 골격): 처음 설정 · 등록 대기/세션 · 대화방 목록 · 대화. 꾸밈 없이 코어 동작을 눌러 볼 수 있는 최소 UI — C 단계가 다듬는다.
package com.seoyoon_family.hande.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Snackbar
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.seoyoon_family.hande.core.DeviceHub
import com.seoyoon_family.hande.core.HubUi
import com.seoyoon_family.hande.core.MessageUi
import com.seoyoon_family.hande.core.Phase
import com.seoyoon_family.hande.core.RoomUi
import com.seoyoon_family.hande.core.Settings
import kotlinx.coroutines.delay

@Composable
fun HandeRoot(hub: DeviceHub) {
    val ui by hub.ui.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    var openRoom by rememberSaveable { mutableStateOf<String?>(null) }

    when (val phase = ui.phase) {
        Phase.Setup -> SetupScreen(hub.settings) { hub.start(scope) }
        is Phase.WaitingEnrollment -> EnrollScreen(ui, phase.json) { hub.retryEnrollment(scope) }
        Phase.NeedsLogin -> LoginScreen(hub.settings) { hub.reconfigure(scope) }
        is Phase.Fatal -> MessageScreen("앱을 시작할 수 없습니다", phase.message)
        Phase.Starting -> MessageScreen(Strings.appName, Strings.starting)
        Phase.Ready -> {
            val room = openRoom?.let { name -> ui.rooms.firstOrNull { it.room == name } }
            if (room != null) {
                RoomScreen(room, ui, onBack = { openRoom = null }, onSend = { text -> hub.send(scope, room.room, text) }, onNoticeShown = hub::clearNotice)
            } else {
                RoomListScreen(ui, onOpen = { openRoom = it }, onRequestJoin = { hub.requestJoin(scope) }, onNoticeShown = hub::clearNotice)
            }
        }
    }
}

@Composable
private fun MessageScreen(title: String, body: String) {
    Column(Modifier.fillMaxSize().padding(24.dp), verticalArrangement = Arrangement.Center) {
        Text(title, style = MaterialTheme.typography.titleLarge)
        Spacer(Modifier.height(12.dp))
        Text(body)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SetupScreen(settings: Settings, onSaved: () -> Unit) {
    var relay by rememberSaveable { mutableStateOf(settings.relayUrl ?: "") }
    var actor by rememberSaveable { mutableStateOf(settings.actor ?: "") }
    var token by rememberSaveable { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    Scaffold(topBar = { TopAppBar(title = { Text(Strings.setupTitle) }) }) { pad ->
        Column(Modifier.padding(pad).verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            OutlinedTextField(relay, { relay = it }, label = { Text(Strings.relayField) }, supportingText = { Text(Strings.relayHint) }, singleLine = true, modifier = Modifier.fillMaxWidth())
            Text(Strings.actorTitle, style = MaterialTheme.typography.titleMedium)
            OutlinedTextField(actor, { actor = it.lowercase() }, label = { Text(Strings.actorField) }, supportingText = { Text(Strings.actorHint) }, singleLine = true, modifier = Modifier.fillMaxWidth(), enabled = settings.actor == null)
            OutlinedTextField(token, { token = it }, label = { Text(Strings.tokenField) }, supportingText = { Text(Strings.tokenHint) }, singleLine = true, modifier = Modifier.fillMaxWidth())
            error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            Button(onClick = {
                when {
                    !relay.trim().startsWith("http") -> error = Strings.relayHint
                    settings.actor == null && !Settings.validActor(actor.trim()) -> error = Strings.actorInvalid
                    else -> {
                        settings.relayUrl = relay
                        if (settings.actor == null) settings.actor = actor.trim()
                        if (token.isNotBlank()) settings.accessToken = token
                        onSaved()
                    }
                }
            }) { Text(Strings.save) }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun EnrollScreen(ui: HubUi, json: String, onRetry: () -> Unit) {
    val clipboard = LocalClipboardManager.current
    var copied by remember { mutableStateOf(false) }
    Scaffold(topBar = { TopAppBar(title = { Text(Strings.enrollTitle) }) }) { pad ->
        Column(Modifier.padding(pad).verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(Strings.enrollBody)
            Text(Strings.fingerprintLabel, style = MaterialTheme.typography.labelLarge)
            Text(ui.fingerprint ?: "", fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall)
            Text(ui.deviceId ?: "", fontFamily = FontFamily.Monospace)
            Card { Text(json, Modifier.padding(12.dp), fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall) }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = { clipboard.setText(AnnotatedString(json)); copied = true }) { Text(if (copied) Strings.copied else Strings.copyRegistration) }
                TextButton(onClick = onRetry) { Text(Strings.enrolledButton) }
            }
            Text(Strings.waitingOperator, style = MaterialTheme.typography.bodySmall)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LoginScreen(settings: Settings, onSaved: () -> Unit) {
    var token by rememberSaveable { mutableStateOf("") }
    Scaffold(topBar = { TopAppBar(title = { Text(Strings.loginTitle) }) }) { pad ->
        Column(Modifier.padding(pad).verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(Strings.loginBody)
            OutlinedTextField(token, { token = it }, label = { Text(Strings.tokenField) }, singleLine = true, modifier = Modifier.fillMaxWidth())
            Button(enabled = token.isNotBlank(), onClick = { settings.accessToken = token; onSaved() }) { Text(Strings.loginButton) }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RoomListScreen(ui: HubUi, onOpen: (String) -> Unit, onRequestJoin: () -> Unit, onNoticeShown: () -> Unit) {
    Scaffold(
        topBar = { TopAppBar(title = { Text(if (ui.connecting) Strings.connecting else Strings.roomsTitle) }) },
        snackbarHost = { NoticeHost(ui.notice, onNoticeShown) },
    ) { pad ->
        Column(Modifier.padding(pad).fillMaxSize()) {
            if (ui.rooms.isEmpty()) {
                Text(Strings.noRooms, Modifier.padding(16.dp))
            } else {
                LazyColumn(Modifier.weight(1f)) {
                    items(ui.rooms, key = { it.room }) { r ->
                        ListItem(
                            headlineContent = { Text(r.room) },
                            supportingContent = {
                                Text(r.halted?.let { "${Strings.halted} · $it" } ?: if (!r.joined) Strings.notJoined else (r.messages.lastOrNull()?.text ?: ""))
                            },
                            modifier = Modifier.fillMaxWidth().clickable { onOpen(r.room) },
                        )
                        HorizontalDivider()
                    }
                }
            }
            if (ui.rooms.isEmpty()) Spacer(Modifier.weight(1f))
            HorizontalDivider()
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("${ui.deviceId ?: ""}", fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall)
                Text("${Strings.lobbyKeys} ${ui.lobbyLive ?: "-"}/${ui.lobbyMax ?: "-"} · ${Strings.keyCustody}: ${ui.keyCustody ?: "-"}", style = MaterialTheme.typography.bodySmall)
                Button(onClick = onRequestJoin, modifier = Modifier.fillMaxWidth()) { Text(Strings.requestJoin) }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RoomScreen(room: RoomUi, ui: HubUi, onBack: () -> Unit, onSend: (String) -> Unit, onNoticeShown: () -> Unit) {
    var draft by rememberSaveable(room.room) { mutableStateOf("") }
    val listState = rememberLazyListState()
    LaunchedEffect(room.messages.size) { if (room.messages.isNotEmpty()) listState.animateScrollToItem(room.messages.size - 1) }
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(if (ui.connecting) Strings.connecting else room.room) },
                navigationIcon = { TextButton(onClick = onBack) { Text(Strings.back) } },
            )
        },
        snackbarHost = { NoticeHost(ui.notice, onNoticeShown) },
    ) { pad ->
        Column(Modifier.padding(pad).fillMaxSize()) {
            LazyColumn(Modifier.weight(1f).fillMaxWidth(), state = listState, contentPadding = PaddingValues(12.dp)) {
                items(room.messages, key = { "${it.sender}-${it.seq}" }) { m -> MessageRow(m) }
            }
            if (room.halted != null) {
                Text("${Strings.halted} · ${room.halted}", Modifier.padding(12.dp), color = MaterialTheme.colorScheme.error)
            } else if (!room.joined) {
                Text(Strings.notJoined, Modifier.padding(12.dp))
            } else {
                Row(Modifier.padding(8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(draft, { draft = it }, Modifier.weight(1f), placeholder = { Text(Strings.composerPlaceholder) }, maxLines = 4)
                    Button(enabled = draft.isNotBlank(), onClick = { onSend(draft.trim()); draft = "" }) { Text(Strings.sendButton) }
                }
            }
        }
    }
}

@Composable
private fun MessageRow(m: MessageUi) {
    Row(Modifier.fillMaxWidth().padding(vertical = 3.dp), horizontalArrangement = if (m.mine) Arrangement.End else Arrangement.Start) {
        if (m.mine) Spacer(Modifier.width(48.dp))
        Card {
            Column(Modifier.padding(10.dp)) {
                if (!m.mine) Text(m.sender.substringBefore('-'), style = MaterialTheme.typography.labelSmall)
                Text(m.text)
            }
        }
        if (!m.mine) Spacer(Modifier.width(48.dp))
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

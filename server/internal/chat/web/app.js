"use strict";
const $ = (id) => document.getElementById(id);
const names = {alice: "앨리스", bob: "밥", charlie: "찰리"};
const encoder = new TextEncoder();
let current = null;
let listVersion = 0;
let roomList = [];

class APIError extends Error {
  constructor(status) { super(`HTTP ${status}`); this.status = status; }
}
class ProtocolError extends Error {}
function statusText(error) {
  return ({400:"입력 내용을 확인해 주세요.",403:"이 대화방에 접근할 수 없습니다.",409:"같은 ID가 이미 사용되었습니다.",507:"시험 저장 한도에 도달했습니다."})[error.status] || "연결을 확인한 뒤 다시 시도해 주세요.";
}
async function api(actor, path, options = {}) {
  const signal = path.includes("/events?") ? options.signal : AbortSignal.any([...(options.signal ? [options.signal] : []), AbortSignal.timeout(path.includes("/attachments") ? 35000 : 10000)]);
  const response = await fetch(path, {...options, signal, credentials:"omit", cache:"no-store",
    headers:{"Authorization":`Bearer synthetic-${actor}`, "Content-Type":"application/json", ...options.headers}});
  if (!response.ok) { await response.body?.cancel(); throw new APIError(response.status); }
  return response;
}
function pendingKey(s) { return `family-synthetic-pending-v1:${s.actor}:${s.room}`; }
function pendingLoad(s) {
  const value = sessionStorage.getItem(pendingKey(s));
  if (value === null) return null;
  const p = JSON.parse(value);
  if (p.actor !== s.actor || p.room !== s.room || !/^[A-Za-z0-9_-]{1,64}$/.test(p.client_id) || (typeof p.payload !== "string" && !(p.payload === null && validDraft(p.media)))) throw new ProtocolError();
  if (p.media && !validDraft(p.media)) throw new ProtocolError();
  if (p.payload === null) return p;
  const bytes = atob(p.payload);
  if (!bytes.length || bytes.length > 16384) throw new ProtocolError();
  return p;
}
function bytesText(payload) {
  try { return new TextDecoder("utf-8",{fatal:true}).decode(Uint8Array.from(atob(payload),c=>c.charCodeAt(0))); }
  catch { return "[텍스트가 아닌 시험 데이터]"; }
}
function controls(s) {
  if (current !== s) return;
  $("file").disabled = s.disabled || s.busy || !!s.pending?.payload;
  $("message").disabled = s.disabled || !!s.pending || s.busy;
  $("send").disabled = s.disabled || !!s.pending || s.busy;
  $("retry").hidden = !s.pending;
  $("retry").disabled = s.disabled || s.busy;
}
function acknowledge(s, m) {
  if (s.pending && m.actor === s.actor && m.client_id === s.pending.client_id && m.payload === s.pending.payload) {
    try { sessionStorage.removeItem(pendingKey(s)); }
    catch { s.disabled = true; $("send-status").textContent = "대기 기록을 갱신할 수 없습니다. 이 탭을 새로고침해 주세요."; controls(s); return; }
    s.pending = null; $("file").value = "";
    if (current === s) { $("message").value = ""; $("send-status").textContent = "전송을 확인했습니다."; controls(s); }
  }
}
function renderMessage(s, m, eventID) {
  if (current !== s) return;
  if (!Number.isSafeInteger(m.seq) || m.seq < 1 || String(m.seq) !== eventID || m.room !== s.room || !Object.hasOwn(names,m.actor) || typeof m.payload !== "string" || m.payload.length > 21848 || typeof m.client_id !== "string" || !Number.isSafeInteger(m.created_ms)) throw new ProtocolError();
  if (m.seq <= s.seq) return;
  if (m.seq !== s.seq + 1) throw new ProtocolError();
  const li = document.createElement("li");
  li.dataset.seq = String(m.seq);
  if (m.actor === s.actor) li.className = "mine";
  const meta = document.createElement("div"); meta.className = "meta";
  meta.textContent = `${names[m.actor]} · ${new Date(m.created_ms).toLocaleTimeString("ko-KR",{hour:"2-digit",minute:"2-digit"})}`;
  const body = document.createElement("div"); body.className = "body"; renderBody(s,m,body);
  li.append(meta,body); $("messages").append(li);
  while ($("messages").children.length > 200) removeMessage(s,$("messages").firstChild);
  $("messages").scrollTop = $("messages").scrollHeight;
  $("empty").hidden = true;
  s.seq = m.seq; // Only advance after validating and applying the whole event.
  $("messages").dataset.cursor = String(s.seq);
  acknowledge(s,m);
}
async function readStream(s, response, signal, alive) {
  const reader = response.body.getReader();
  const decoder = new TextDecoder("utf-8",{fatal:true});
  let buffer = "";
  try {
    while (!signal.aborted && current === s) {
      const {value,done} = await reader.read();
      if (done) break; // Discard an incomplete event; replay starts from applied seq.
      buffer += decoder.decode(value,{stream:true});
      let end;
      while ((end = buffer.indexOf("\n\n")) !== -1) {
        const frame = buffer.slice(0,end); buffer = buffer.slice(end+2);
        if (frame.length > 32768) throw new ProtocolError();
        const fields = frame.split("\n");
        const data = fields.filter(x=>x.startsWith("data: "));
        if (!data.length) {alive();continue;}
        const ids = fields.filter(x=>x.startsWith("id: "));
        if (data.length !== 1 || ids.length !== 1 || !fields.includes("event: message")) throw new ProtocolError();
        renderMessage(s,JSON.parse(data[0].slice(6)),ids[0].slice(4));alive();
      }
      if (buffer.length > 32768) throw new ProtocolError();
    }
  } finally { await reader.cancel().catch(()=>{}); reader.releaseLock(); }
}
function pause(ms,signal) {
  return new Promise(resolve=>{
    if (signal.aborted) return resolve();
    const done = ()=>{clearTimeout(timer);signal.removeEventListener("abort",done);resolve();};
    const timer = setTimeout(done,ms);signal.addEventListener("abort",done,{once:true});
  });
}
function denied(s) {
  if (current !== s) return;
  s.disabled = true; s.controller.abort(); clearMedia(s);
  $("messages").replaceChildren(); $("empty").hidden = false;
  $("empty").textContent = "이 대화방에 접근할 수 없습니다.";
  $("connection").textContent = "접근 권한이 없습니다.";
  $("owner-tools").hidden = true; controls(s);
}
async function connect(s,controller) {
  let delay = 500;
  while (current === s && !controller.signal.aborted) {
    const attempt = new AbortController();
    const stop = ()=>attempt.abort();
    controller.signal.addEventListener("abort",stop,{once:true});
    let watchdog;
    let openedAt;
    const alive = ()=>{clearTimeout(watchdog);watchdog=setTimeout(stop,25000);};
    alive(); // Bounds both missing response headers and missing complete SSE frames.
    try {
      $("connection").textContent = s.seq ? "대화를 이어 받는 중…" : "대화를 불러오는 중…";
      const response = await api(s.actor,`/v1/rooms/${s.room}/events?after=${s.seq}`,{signal:attempt.signal});
      openedAt = performance.now();alive();
      if (!response.headers.get("Content-Type")?.startsWith("text/event-stream")) {await response.body?.cancel(); throw new ProtocolError();}
      if (current !== s || controller.signal.aborted) {await response.body.cancel(); return;}
      $("connection").textContent = "연결됨";
      await readStream(s,response,attempt.signal,alive);
    } catch (e) {
      if (current !== s || controller.signal.aborted) return;
      if (e.status === 403) {denied(s);return;}
      if (e instanceof ProtocolError || e instanceof SyntaxError || e.status === 400) {
        s.disabled = true; controls(s); $("connection").textContent = "이력을 확인할 수 없습니다. 방을 다시 선택해 주세요."; return;
      }
    } finally {
      clearTimeout(watchdog);controller.signal.removeEventListener("abort",stop);attempt.abort();
    }
    if (current !== s || controller.signal.aborted) return;
    // Normal 30s rotation should not accumulate an 8s delivery gap. Short,
    // repeatedly failing attempts still back off even if headers were received.
    if (openedAt !== undefined && performance.now()-openedAt >= 10000) delay=500;
    $("connection").textContent = "연결이 끊겼습니다. 자동으로 다시 연결합니다.";
    await pause(delay,controller.signal); delay = Math.min(delay*2,8000);
  }
}
function selectRoom(room) {
  current?.controller.abort(); if(current) clearMedia(current);
  const s = {actor:$("actor").value,room:room.id,owner:room.owner,seq:0,controller:new AbortController(),pending:null,busy:false,disabled:false,mediaBusy:false,preview:null};
  current = s;
  $("room-title").textContent = room.id;
  $("messages").replaceChildren(); $("messages").dataset.cursor = "0";
  $("empty").hidden = false; $("empty").textContent = "첫 시험 메시지를 보내 보세요.";
  $("send-status").textContent = ""; $("message").value = ""; $("file").value = "";
  $("owner-tools").hidden = room.owner !== s.actor; $("reconnect").disabled = false;
  for (const button of $("rooms").children) button.setAttribute("aria-current",String(button.dataset.room === s.room));
  try {
    s.pending = pendingLoad(s);
    if (s.pending) {$("message").value = s.pending.payload ? draftText(s.pending.payload) : "";$("send-status").textContent = "확인되지 않은 전송이 있습니다. 같은 요청으로 다시 확인할 수 있습니다.";}
  } catch {s.disabled = true;$("send-status").textContent = "대기 기록을 읽을 수 없습니다. 새 시험 탭을 사용해 주세요.";}
  controls(s); connect(s,s.controller);
}
function clearRoom() {
  current?.controller.abort(); if(current) clearMedia(current); current = null;
  $("room-title").textContent = "대화방을 선택하세요";$("messages").replaceChildren();
  $("empty").hidden = false;$("empty").textContent = "새 대화방을 만들거나 목록에서 선택해 주세요.";
  $("owner-tools").hidden = true;$("message").value = "";$("send-status").textContent = "";
  $("file").disabled = true;$("file").value = "";$("message").disabled = true;$("send").disabled = true;$("retry").hidden = true;$("reconnect").disabled = true;
}
async function refreshRooms(preferred) {
  const version = ++listVersion, actor = $("actor").value;
  try {
    const response = await api(actor,"/v1/rooms");const rooms = await response.json();
    if (version !== listVersion || actor !== $("actor").value) return;
    roomList = rooms; $("rooms").replaceChildren();
    for (const room of rooms) {
      const b = document.createElement("button");b.type = "button";b.dataset.room = room.id;b.textContent = room.id;
      b.addEventListener("click",()=>selectRoom(room));$("rooms").append(b);
    }
    $("room-note").textContent = rooms.length ? `${rooms.length}개의 대화방` : "참여한 대화방이 없습니다.";
    const selected = rooms.find(r=>r.id === (preferred || current?.room)) || rooms[0];
    if (selected && (!current || selected.id !== current.room || current.disabled || preferred)) selectRoom(selected);
    else if (!selected) {clearRoom();$("connection").textContent = "시험 대화방을 만들어 주세요.";}
    else for (const b of $("rooms").children) b.setAttribute("aria-current",String(b.dataset.room === current.room));
  } catch(e) {if(version === listVersion) $("room-note").textContent = statusText(e);}
}
async function transmit(s) {
  if (!s.pending || s.busy || s.disabled || current !== s) return;
  s.busy = true;controls(s);$("send-status").textContent = "전송을 확인하는 중…";
  let p = s.pending;
  try {
    if (!p.payload) {
      p = await uploadPending(s,p);
      if (current !== s || s.disabled) return;
    }
    const response = await api(s.actor,`/v1/rooms/${s.room}/messages`,{method:"POST",body:JSON.stringify({client_id:p.client_id,payload:p.payload}),signal:s.controller.signal});
    const m = await response.json();
    if (current === s) acknowledge(s,m);
  } catch(e) {
    if (current === s && s.pending) {
      $("send-status").textContent = e.status ? statusText(e) : (e instanceof TypeError || e.name === "TimeoutError" || e.name === "AbortError" ? "전송 결과를 확인하지 못했습니다. 같은 요청으로 다시 확인해 주세요." : e.message || "전송 결과를 확인하지 못했습니다.");
      if (e.status === 403) denied(s);
    }
  } finally {s.busy = false;controls(s);}
}
$("send-form").addEventListener("submit",async event=>{
  event.preventDefault();const s=current;
  if (!s || s.disabled || s.pending || s.busy) return;
  if ($("file").files.length) { await stageFile(s,$("file").files[0]); return; }
  const text = $("message").value;
  const payload = pack({type:"text",text});
  if (!text.length || atob(payload).length>16384) {$("send-status").textContent="메시지는 UTF-8 기준 16 KiB까지 보낼 수 있습니다.";return;}
  const p={actor:s.actor,room:s.room,client_id:crypto.randomUUID(),payload};
  try {sessionStorage.setItem(pendingKey(s),JSON.stringify(p));}
  catch {$("send-status").textContent="대기 기록을 저장할 수 없어 전송하지 않았습니다.";return;}
  s.pending=p;transmit(s);
});
$("retry").addEventListener("click",()=>{if(current)transmit(current);});
$("message").addEventListener("keydown",event=>{if(event.key==="Enter"&&!event.shiftKey&&!event.isComposing){event.preventDefault();$("send-form").requestSubmit();}});
$("actor").addEventListener("change",()=>{clearRoom();refreshRooms();});
$("refresh").addEventListener("click",()=>refreshRooms());
$("reconnect").addEventListener("click",()=>{if(current){const r=roomList.find(r=>r.id===current.room);if(r)selectRoom(r);}});
$("create-form").addEventListener("submit",async event=>{
  event.preventDefault();const actor=$("actor").value,id=$("room-id").value;
  const button=event.submitter || $("create-form").querySelector("button");button.disabled=true;
  try {
    await api(actor,"/v1/rooms",{method:"POST",body:JSON.stringify({id,members:[...document.querySelectorAll('[name="member"]:checked')].map(e=>e.value)})});
    if(actor===$("actor").value){$("room-id").value="";await refreshRooms(id);}
  }catch(e){if(actor===$("actor").value)$("room-note").textContent=statusText(e);}
  finally{button.disabled=false;}
});
async function membership(present){
  const s=current;if(!s||s.actor!==s.owner)return;
  try{await api(s.actor,`/v1/rooms/${s.room}/members/${$("member-actor").value}`,{method:present?"PUT":"DELETE"});if(current===s)$("send-status").textContent=present?"시험 계정을 추가했습니다.":"시험 계정을 제외했습니다.";}
  catch(e){if(current===s)$("send-status").textContent=statusText(e);}
}
$("add-member").addEventListener("click",()=>membership(true));
$("remove-member").addEventListener("click",()=>membership(false));
refreshRooms();

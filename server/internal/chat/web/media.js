"use strict";
// Versioned opaque payload. Legacy unframed UTF-8 remains text; new text is
// framed too, so writing the reserved prefix cannot fabricate an attachment.
const envelopePrefix = "\u001eFAMILY/1\n";
const maxFile = 8 * 1024 * 1024;
function pack(value) {return btoa(String.fromCharCode(...encoder.encode(envelopePrefix+JSON.stringify(value))));}
function unpack(payload) {
  const text=bytesText(payload);
  if (!text.startsWith(envelopePrefix)) return {type:"text",text};
  try {
    const value=JSON.parse(text.slice(envelopePrefix.length));
    if(value?.type==="text" && typeof value.text==="string")return value;
    if(value?.type==="attachment" && validMeta(value.attachment))return value;
  } catch {}
  return {type:"text",text:"[지원하지 않는 메시지 형식]"};
}
function draftText(payload) {const v=unpack(payload);return v.type==="text"?v.text:"";}
function validDraft(m) {
  return m && typeof m.filename==="string" && encoder.encode(m.filename).length>0 && encoder.encode(m.filename).length<=180 &&
    !/[\/\\\p{Cc}\p{Cf}]/u.test(m.filename) && ![".",".."].includes(m.filename) &&
    typeof m.media_type==="string" && /^[a-z0-9!#$&^_.+-]+\/[a-z0-9!#$&^_.+-]+$/.test(m.media_type) && m.media_type.length<=100 &&
    Number.isSafeInteger(m.size) && m.size>0 && m.size<=maxFile && /^[0-9a-f]{64}$/.test(m.sha256) && /^[A-Za-z0-9_-]{1,64}$/.test(m.client_id);
}
function validMeta(m) {return validDraft(m) && /^[0-9a-f]{32}$/.test(m.id) && /^[A-Za-z0-9_-]{1,64}$/.test(m.room) && Object.hasOwn(names,m.actor) && Number.isSafeInteger(m.created_ms);}
function sameDraft(a,b) {return ["filename","media_type","size","sha256","client_id"].every(k=>a[k]===b[k]);}
function sameMeta(a,b) {return sameDraft(a,b) && ["id","room","actor","created_ms"].every(k=>a[k]===b[k]);}
async function digest(bytes) {return [...new Uint8Array(await crypto.subtle.digest("SHA-256",bytes))].map(x=>x.toString(16).padStart(2,"0")).join("");}
async function describe(file,clientID) {
  if(file.size<1 || file.size>maxFile) throw new Error("파일은 1바이트부터 8 MiB까지 보낼 수 있습니다.");
  const m={filename:file.name,media_type:file.type.toLowerCase()||"application/octet-stream",size:file.size,sha256:await digest(await file.arrayBuffer()),client_id:clientID};
  if(!validDraft(m))throw new Error("파일 이름이나 형식을 확인해 주세요.");
  return m;
}
async function stageFile(s,file) {
  if($("message").value.length){$("send-status").textContent="첨부파일과 글은 각각 보내 주세요.";return;}
  s.busy=true;controls(s);
  try {
    const media=await describe(file,crypto.randomUUID());
    if(current!==s || s.disabled)return;
    const p={actor:s.actor,room:s.room,client_id:crypto.randomUUID(),payload:null,media};
    sessionStorage.setItem(pendingKey(s),JSON.stringify(p));s.pending=p;s.file=file;
  } catch(e) {if(current===s)$("send-status").textContent=e.message;}
  finally {s.busy=false;controls(s);}
  if(s.pending)transmit(s);
}
async function uploadPending(s,p) {
  const file=s.file || $("file").files[0];
  if(!file)throw new Error("같은 파일을 다시 선택한 뒤 전송을 확인해 주세요.");
  const actual=await describe(file,p.media.client_id);
  if(!sameDraft(actual,p.media))throw new Error("처음 선택한 파일과 다릅니다. 같은 이름과 내용의 파일을 선택해 주세요.");
  if(current!==s || s.disabled)throw new Error("대화방이 변경되었습니다.");
  $("send-status").textContent="파일을 올리는 중… 아직 메시지는 전송되지 않았습니다.";
  const response=await api(s.actor,`/v1/rooms/${s.room}/attachments`,{method:"POST",body:file,signal:s.controller.signal,
    headers:{"Content-Type":p.media.media_type,"X-Upload-ID":p.media.client_id,"X-File-Name":encodeURIComponent(p.media.filename),"X-Content-SHA256":p.media.sha256}});
  const m=await response.json();
  if(!validMeta(m)||!sameDraft(m,p.media)||m.room!==s.room||m.actor!==s.actor)throw new ProtocolError();
  if(current!==s || s.disabled)throw new Error("대화방이 변경되었습니다.");
  const next={...p,payload:pack({type:"attachment",attachment:m})};
  // Persist the immutable message before sending it. If this write fails the
  // old upload draft is retained; retrying it yields this same stored object.
  sessionStorage.setItem(pendingKey(s),JSON.stringify(next));s.pending=next;s.file=null;
  $("send-status").textContent="파일 저장 완료 · 메시지 전송을 확인하는 중…";
  return next;
}
function clearMedia(s) {
  s.mediaController?.abort();s.mediaController=null;
  if(s.preview){
    const {node,url}=s.preview;
    for(const v of node.querySelectorAll("video")){v.pause();v.removeAttribute("src");v.load();}
    node.replaceChildren();URL.revokeObjectURL(url);s.preview=null;
  }
}
function removeMessage(s,node){if(s.preview && node.contains(s.preview.node))clearMedia(s);node.remove();}
function renderBody(s,m,body) {
  const v=unpack(m.payload);
  if(v.type==="text"){body.textContent=v.text;return;}
  const meta=v.attachment;
  if(meta.room!==s.room||meta.actor!==m.actor){body.textContent="[첨부 정보가 일치하지 않습니다]";return;}
  body.classList.add("attachment");body.dataset.attachment=meta.id;
  const title=document.createElement("strong");title.textContent=meta.filename;
  const size=document.createElement("small");size.textContent=`${(meta.size/1024).toFixed(1)} KiB`;
  const open=document.createElement("button");open.type="button";open.className="quiet open-media";open.textContent="파일 열기";
  const download=document.createElement("button");download.type="button";download.className="quiet download-media";download.textContent="다운로드";
  const note=document.createElement("span");note.className="media-note";note.setAttribute("role","status");
  const preview=document.createElement("div");preview.className="preview";
  body.append(title,size,open,download,note,preview);
  open.addEventListener("click",()=>loadMedia(s,meta,preview,note,false));
  download.addEventListener("click",()=>loadMedia(s,meta,preview,note,true));
}
async function boundedBytes(response,size) {
  if(response.headers.get("Content-Length")!==String(size)) {await response.body?.cancel();throw new ProtocolError();}
  const reader=response.body.getReader(), bytes=new Uint8Array(size);let count=0;
  try {
    while(true){const {done,value}=await reader.read();if(done)break;if(count+value.length>size)throw new ProtocolError();bytes.set(value,count);count+=value.length;}
    if(count!==size)throw new ProtocolError();return bytes;
  }finally{await reader.cancel().catch(()=>{});reader.releaseLock();}
}
async function loadMedia(s,m,node,note,download) {
  if(current!==s||s.disabled||s.mediaBusy)return;
  clearMedia(s);s.mediaBusy=true;
  const controller=new AbortController();s.mediaController=controller;
  const signal=AbortSignal.any([controller.signal,s.controller.signal,AbortSignal.timeout(35000)]);
  note.textContent="파일을 확인하는 중…";
  try {
    const list=await (await api(s.actor,`/v1/rooms/${s.room}/attachments`,{signal})).json();
    if(!Array.isArray(list)||list.length>128||!list.some(x=>validMeta(x)&&sameMeta(x,m)))throw new ProtocolError();
    const response=await api(s.actor,`/v1/rooms/${s.room}/attachments/${m.id}`,{signal});
    if(response.headers.get("X-Content-SHA256")!==m.sha256){await response.body?.cancel();throw new ProtocolError();}
    const bytes=await boundedBytes(response,m.size);
    if(await digest(bytes)!==m.sha256)throw new ProtocolError();
    // Check membership again after the full read/hash. In-flight bytes and
    // downloaded files cannot be recalled; SSE denial clears the live preview.
    await api(s.actor,`/v1/rooms/${s.room}/attachments`,{signal}).then(r=>r.body.cancel());
    if(current!==s||s.disabled||signal.aborted||!node.isConnected)return;
    const kind=["image/png","image/jpeg","image/webp","video/mp4","video/webm"].includes(m.media_type)?m.media_type:"application/octet-stream";
    const url=URL.createObjectURL(new Blob([bytes],{type:download?"application/octet-stream":kind}));s.preview={node,url};
    if(download){const a=document.createElement("a");a.href=url;a.download=m.filename;node.append(a);a.click();a.remove();note.textContent="파일 무결성을 확인해 다운로드했습니다.";return;}
    if(kind.startsWith("image/")){const img=document.createElement("img");img.alt=m.filename;img.src=url;node.append(img);}
    else if(kind.startsWith("video/")){const video=document.createElement("video");video.controls=true;video.preload="metadata";video.playsInline=true;video.src=url;node.append(video);}
    else {clearMedia(s);note.textContent="미리보기를 지원하지 않는 파일입니다. 다운로드해 주세요.";return;}
    note.textContent="무결성 확인 완료";
  }catch(e){if(current===s&&!s.disabled){note.textContent=e instanceof ProtocolError?"파일 정보를 확인할 수 없습니다.":statusText(e);if(e.status===403)denied(s);}}
  finally{s.mediaBusy=false;if(s.mediaController===controller)s.mediaController=null;}
}

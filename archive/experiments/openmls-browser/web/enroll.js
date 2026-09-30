// Fingerprint comparison screens (#177 M3c, DEVICES-V4.md): the new-device screen
// shows this device's own fingerprint; the trusted-device screen shows a candidate's
// fingerprint for the one-time out-of-band comparison. Only fingerprints are ever
// rendered — never keys. Comparing the values is the human's step (synthetic here);
// this UI only renders both sides and gates the approval signature behind the
// explicit "이 지문이 맞습니다" action. Self-contained on purpose: every smoke
// serves this file, so it must not import other page modules.
const hex = bytes => Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');
// Same identifier shape the facade validates (alphanumeric plus _.:-).
const name = s => typeof s === 'string' && /^[a-zA-Z0-9_.:-]{1,64}$/.test(s);
const el = id => document.getElementById(id);

window.enroll = {
  candidate: null,
  evidence: null,
  denied: false,

  // 새 기기 화면: own identity + own fingerprint.
  async show_own(identity) {
    if (!name(identity)) throw new Error('rejected');
    el('device-identity').textContent = identity;
    // window.call resolves the whole worker envelope {id, ok, result, ...}; render
    // only the result, and never silently "[object Object]" a failed RPC.
    const own = await call('main', 'fingerprint');
    if (!own.ok) throw new Error('fingerprint rpc failed');
    el('own-fingerprint').textContent = own.result;
    el('device-screen').hidden = false;
  },

  // 신뢰 기기 화면: render the candidate's fingerprint (derived here from the
  // candidate key the enrollment request carries) and arm the decision buttons.
  async offer(candidate) {
    if (this.candidate || this.evidence) throw new Error('ceremony busy');
    const c = candidate || {};
    if (!name(c.device_id) || !name(c.actor) || !name(c.subject)
        || typeof c.signing_key !== 'string' || !/^[a-f0-9]{64}$/.test(c.signing_key)
        || !Number.isSafeInteger(c.base_revision) || c.base_revision < 1) throw new Error('rejected');
    el('candidate-identity').textContent = `${c.device_id} (${c.actor})`;
    const shown = await call('main', 'policy_fingerprint', c.signing_key);
    if (!shown.ok) throw new Error('fingerprint rpc failed');
    el('candidate-fingerprint').textContent = shown.result;
    this.candidate = c;
    el('trust-screen').hidden = false;
    el('approve').disabled = el('deny').disabled = false;
  },

  async decide(accept) {
    if (!this.candidate || this.evidence) throw new Error('no ceremony');
    el('approve').disabled = el('deny').disabled = true;
    if (!accept) {
      this.denied = true;
      this.candidate = null;  // a fresh offer may be made; nothing was signed
      return;
    }
    const framedReply = await call('main', 'sign_approval', {
      action: 'approve-device', device_id: this.candidate.device_id, actor: this.candidate.actor,
      subject: this.candidate.subject, signing_key: this.candidate.signing_key,
      acceptance: 'trusted-device-fingerprint', base_revision: this.candidate.base_revision,
    });
    if (!framedReply.ok) throw new Error('sign_approval rpc failed');
    const framed = framedReply.result;
    const view = new DataView(new Uint8Array(framed).buffer);
    const canonical_len = view.getUint32(0, true);
    this.evidence = {
      canonical: framed.slice(4, 4 + canonical_len),
      signature: hex(framed.slice(4 + canonical_len)),
      candidate: this.candidate,
      fingerprint: el('candidate-fingerprint').textContent,
    };
  },
};

window.addEventListener('DOMContentLoaded', () => {
  el('approve').addEventListener('click', () => window.enroll.decide(true));
  el('deny').addEventListener('click', () => window.enroll.decide(false));
});

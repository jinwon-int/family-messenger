// Isolated generated-data archive probe. Never load real MLS state here.
import {Encrypter, Decrypter} from 'age-encryption';

let busy = false, retired = false;
const expected = () => new Uint8Array(2048).fill(42); // Public dummy fixture, not a key.
function bytes(value) {
  if (!Array.isArray(value) || value.length < 1 || value.length > 8192 ||
      !value.every(x => Number.isInteger(x) && x >= 0 && x <= 255)) throw Error('input');
  return new Uint8Array(value); // Private snapshot shared by inspection and decrypt.
}

async function admit(ciphertext) {
  // Let the pinned library parse its own format. This policy identity never
  // unwraps/returns a key and no password identity is installed in this pass.
  // Only our exact sentinel proves the parser reached an acceptable stanza.
  const accepted = {};
  const inspector = new Decrypter();
  inspector.addIdentity({unwrapFileKey(stanzas) {
    if (stanzas.length !== 1) throw Error('recipients');
    const s = stanzas[0];
    if (s.args.length !== 3 || s.args[0] !== 'scrypt' || s.args[2] !== '18' ||
        s.body.length !== 32) throw Error('work policy');
    throw accepted;
  }});
  try { await inspector.decrypt(ciphertext); }
  catch (error) { if (error === accepted) return; }
  throw Error('admission');
}

self.onmessage = async ({data}) => {
  if (retired) return;
  if (busy) { retired = true; self.postMessage({type:'denied'}); self.close(); return; }
  busy = true;
  const start = performance.now();
  try {
    if (!data || Object.keys(data).sort().join(',') !== 'ciphertext,op,password' ||
        !['create','unlock'].includes(data.op) || typeof data.password !== 'string' ||
        data.password.length < 32 || data.password.length > 128) throw Error('request');
    let result;
    if (data.op === 'create') {
      if (data.ciphertext !== null) throw Error('arguments');
      const encrypter = new Encrypter();
      encrypter.setPassphrase(data.password); // Keep library default logN=18.
      self.postMessage({type:'kdf-start'});
      result = {ciphertext:Array.from(await encrypter.encrypt(expected()))};
    } else {
      const ciphertext = bytes(data.ciphertext);
      await admit(ciphertext); // No KDF on rejected work factors/format/size.
      const decrypter = new Decrypter();
      decrypter.addPassphrase(data.password);
      self.postMessage({type:'kdf-start'});
      const plaintext = await decrypter.decrypt(ciphertext);
      const wanted = expected();
      if (plaintext.length !== wanted.length || !plaintext.every((x,i) => x === wanted[i])) throw Error('fixture');
      result = {matched:true}; // No plaintext/key/provider crosses the worker boundary.
    }
    if (!retired) self.postMessage({type:'done',...result,ms:Math.round(performance.now()-start)});
  } catch { if (!retired) self.postMessage({type:'denied'}); }
  finally { retired = true; self.close(); } // One candidate per worker, no session claim.
};

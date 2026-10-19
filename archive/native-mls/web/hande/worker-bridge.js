// Page ↔ durable worker bridge (openmls-browser web/main.js, as a module instead of
// window globals). One named worker per MLS store; `init` gets its own generous
// deadline because the custody scrypt (logN 18) takes seconds on a desktop core and
// far longer on a phone (#243 2-c) — never lower the KDF to fit a timeout.
export function createWorkerBridge({workerUrl = './durable-worker.js', bootDeadline = 10000, callDeadline = 10000, initDeadline = 180000} = {}) {
  const workers = new Map();
  let serial = 0;
  function spawn(name) {
    return new Promise((resolve, reject) => {
      if (workers.has(name)) { reject(new Error('duplicate worker')); return; }
      const worker = new Worker(workerUrl, {type: 'module'});
      workers.set(name, worker);
      const forget = () => { worker.terminate(); if (workers.get(name) === worker) workers.delete(name); };
      const timer = setTimeout(() => { forget(); reject(new Error('boot deadline')); }, bootDeadline);
      worker.addEventListener('message', function boot({data}) {
        if (data && data.boot) { clearTimeout(timer); worker.removeEventListener('message', boot); resolve(); }
      });
      // A worker that failed to boot must not keep its name (review 2 L-12).
      worker.addEventListener('error', () => { clearTimeout(timer); forget(); reject(new Error('boot failure')); }, {once: true});
    });
  }
  function call(name, method, argument) {
    return new Promise((resolve, reject) => {
      const worker = workers.get(name);
      if (!worker) { reject(new Error('missing worker')); return; }
      const id = ++serial;
      const timer = setTimeout(() => {
        worker.terminate(); if (workers.get(name) === worker) workers.delete(name);
        cleanup(); reject(new Error('worker deadline'));
      }, method === 'init' ? initDeadline : callDeadline);
      const onmessage = ({data}) => { if (data.id !== id) return; cleanup(); resolve(data); };
      const onerror = () => { cleanup(); reject(new Error('worker failure')); };
      function cleanup() { clearTimeout(timer); worker.removeEventListener('message', onmessage); worker.removeEventListener('error', onerror); }
      worker.addEventListener('message', onmessage);
      worker.addEventListener('error', onerror);
      worker.postMessage({id, method, argument});
    });
  }
  function stop(name) { workers.get(name)?.terminate(); workers.delete(name); }
  return {spawn, call, stop, has: name => workers.has(name)};
}

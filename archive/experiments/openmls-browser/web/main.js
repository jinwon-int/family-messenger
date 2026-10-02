// Synthetic harness only. Reload destroys all crypto state; never a product API.
const workers = new Map();
let serial = 0;
window.spawn = (name, durable = false) => new Promise((resolve, reject) => {
  if (workers.has(name)) throw new Error('duplicate worker');
  const worker = new Worker(durable ? './durable-worker.js' : './worker.js', {type: 'module'});
  workers.set(name, worker);
  // M1: only forget this worker if it is still the mapped one — a replacement
  // spawned under the same name after a slow boot must not be dropped.
  const timer = setTimeout(() => { worker.terminate(); if (workers.get(name) === worker) workers.delete(name); reject(new Error('boot deadline')); }, 10000);
  worker.addEventListener('message', function boot({data}) {
    if (data.boot) { clearTimeout(timer); worker.removeEventListener('message', boot); resolve(); }
  });
  // Review 2 L-12: a worker that failed to boot must not keep its name, or every
  // later spawn under that name is refused as a duplicate.
  worker.addEventListener('error', () => { clearTimeout(timer); worker.terminate(); if (workers.get(name) === worker) workers.delete(name); reject(new Error('boot failure')); }, {once: true});
});
window.call = (name, method, argument) => new Promise((resolve, reject) => {
  const worker = workers.get(name);
  if (!worker) return reject(new Error('missing worker'));
  const id = ++serial;
  // `init` of a durable worker runs one custody scrypt (logN 18, #177 M2b-3): about
  // 3 s on one desktop core, several times that on a slow phone. Never lower the KDF;
  // give that call its own deadline instead.
  const timer = setTimeout(() => {
    // M1: terminate the timed-out worker, but only remove it from the map if it
    // is still the current one, so a replacement under the same name survives.
    worker.terminate(); if (workers.get(name) === worker) workers.delete(name); cleanup(); reject(new Error('worker deadline'));
  }, method === 'init' ? 60000 : 10000);
  const onmessage = ({data}) => {
    if (data.id !== id) return;
    cleanup(); resolve(data);
  };
  const onerror = () => { cleanup(); reject(new Error('worker failure')); };
  function cleanup() { clearTimeout(timer); worker.removeEventListener('message', onmessage); worker.removeEventListener('error', onerror); }
  worker.addEventListener('message', onmessage);
  worker.addEventListener('error', onerror);
  worker.postMessage({id, method, argument});
});
window.ready = true;

window.stopWorker = (name) => { workers.get(name)?.terminate(); workers.delete(name); };

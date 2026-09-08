// Synthetic harness only. Reload destroys all crypto state; never a product API.
const workers = new Map();
let serial = 0;
window.spawn = (name) => new Promise((resolve, reject) => {
  if (workers.has(name)) throw new Error('duplicate worker');
  const worker = new Worker('./worker.js', {type: 'module'});
  workers.set(name, worker);
  const timer = setTimeout(() => { worker.terminate(); workers.delete(name); reject(new Error('boot deadline')); }, 10000);
  worker.addEventListener('message', function boot({data}) {
    if (data.boot) { clearTimeout(timer); worker.removeEventListener('message', boot); resolve(); }
  });
  worker.addEventListener('error', () => { clearTimeout(timer); reject(new Error('boot failure')); }, {once: true});
});
window.call = (name, method, argument) => new Promise((resolve, reject) => {
  const worker = workers.get(name);
  if (!worker) return reject(new Error('missing worker'));
  const id = ++serial;
  const timer = setTimeout(() => {
    worker.terminate(); workers.delete(name); cleanup(); reject(new Error('worker deadline'));
  }, 10000);
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

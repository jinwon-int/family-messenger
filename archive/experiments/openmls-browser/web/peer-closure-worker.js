import init from './pkg/family_mls_browser_experiment.js';
import {PeerClosureStore,reservation} from './successor-closure-store.js';
import {closureWorker} from './closure-worker.js';
closureWorker(await init(),new PeerClosureStore(),reservation,'peer');

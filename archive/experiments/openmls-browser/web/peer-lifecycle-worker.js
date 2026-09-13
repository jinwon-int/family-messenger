import init from './pkg/family_mls_browser_experiment.js';
import {PeerClosureStore,reservation} from './successor-closure-store.js';
import {lifecycleWorker} from './successor-lifecycle-worker.js';
lifecycleWorker(await init(),new PeerClosureStore(),reservation,'peer');

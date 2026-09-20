import init from './pkg/family_mls_browser_experiment.js';
import {SuccessorPeerStore,reservation} from './successor-peer-store.js';
import {custodyWorker} from './custody-worker.js';
custodyWorker(await init(),new SuccessorPeerStore(),reservation,'peer');

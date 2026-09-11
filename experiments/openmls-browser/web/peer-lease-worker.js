import init from './pkg/family_mls_browser_experiment.js';
import {PeerLeaseStore,reservation} from './successor-lease-store.js';
import {leaseWorker} from './lease-worker.js';
leaseWorker(await init(),new PeerLeaseStore(),reservation,'peer');

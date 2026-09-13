import init from './pkg/family_mls_browser_experiment.js';
import {PeerRetirementStore,reservation} from './successor-retirement-store.js';
import {retirementWorker} from './retirement-worker.js';
retirementWorker(await init(),new PeerRetirementStore(),reservation,'peer');

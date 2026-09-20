import init from './pkg/family_mls_browser_experiment.js';
import {PeerConfirmationStore,reservation} from './successor-confirmation-store.js';
import {confirmationWorker} from './confirmation-worker.js';
confirmationWorker(await init(),new PeerConfirmationStore(),reservation,'peer');

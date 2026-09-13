import init from './pkg/family_mls_browser_experiment.js';
import {CandidateConfirmationStore,candidateReservation} from './successor-confirmation-store.js';
import {confirmationWorker} from './confirmation-worker.js';
confirmationWorker(await init(),new CandidateConfirmationStore(),candidateReservation,'candidate');

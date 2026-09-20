import init from './pkg/family_mls_browser_experiment.js';
import {CandidateStore,candidateReservation} from './candidate-store.js';
import {custodyWorker} from './custody-worker.js';
custodyWorker(await init(),new CandidateStore(),candidateReservation,'candidate');

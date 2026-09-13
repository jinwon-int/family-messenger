import init from './pkg/family_mls_browser_experiment.js';
import {CandidateRetirementStore,candidateReservation} from './successor-retirement-store.js';
import {retirementWorker} from './retirement-worker.js';
retirementWorker(await init(),new CandidateRetirementStore(),candidateReservation,'candidate');

import init from './pkg/family_mls_browser_experiment.js';
import {CandidateEnrollmentStore,candidateReservation} from './successor-enrollment-store.js';
import {enrollmentWorker} from './enrollment-worker.js';
enrollmentWorker(await init(),new CandidateEnrollmentStore(),candidateReservation,'candidate');

import init from './pkg/family_mls_browser_experiment.js';
import {CandidateClosureStore,candidateReservation} from './successor-closure-store.js';
import {closureWorker} from './closure-worker.js';
closureWorker(await init(),new CandidateClosureStore(),candidateReservation,'candidate');

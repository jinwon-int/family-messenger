import init from './pkg/family_mls_browser_experiment.js';
import {CandidateExchangeStore,candidateReservation} from './successor-exchange-store.js';
import {exchangeWorker} from './exchange-worker.js';
exchangeWorker(await init(),new CandidateExchangeStore(),candidateReservation,'candidate');

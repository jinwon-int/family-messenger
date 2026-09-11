import init from './pkg/family_mls_browser_experiment.js';
import {PeerExchangeStore,reservation} from './successor-exchange-store.js';
import {exchangeWorker} from './exchange-worker.js';
exchangeWorker(await init(),new PeerExchangeStore(),reservation,'peer');

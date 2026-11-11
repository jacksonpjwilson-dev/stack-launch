import path from 'node:path';
import {EncryptedStateFile, PlaidProvider, synchronize} from './sync.mjs';
// Single-owner read-only ingestion job. No public routes; schedule with the host's cron.
// Bootstrap once using an EXISTING authorized Item token. Never create an Item here.
const required = name => { const value = process.env[name]; if (!value) throw new Error('MISSING_' + name); return value; };
try {
  const filename = required('STACK_STATE_FILE');
  if (!path.isAbsolute(filename)) throw new Error('STATE_PATH_MUST_BE_ABSOLUTE');
  const store = new EncryptedStateFile(filename, Buffer.from(required('STACK_ENCRYPTION_KEY'), 'base64'));
  await store.exclusive(async () => {
    let state = await store.load();
    if (!state) {
      state = {itemID: required('PLAID_ITEM_ID'), accessToken: required('PLAID_ACCESS_TOKEN'), transactions: [], cursor: null};
      await store.save(state);
    }
    const provider = new PlaidProvider({clientID: required('PLAID_CLIENT_ID'), secret: required('PLAID_SECRET'), environment: process.env.PLAID_ENV ?? 'sandbox'});
    try {
      const next = await synchronize(state, provider);
      await store.save(next);
      console.log(JSON.stringify({status: 'ok', transactionCount: next.transactions.length, lastSuccess: next.lastSuccess}));
    } catch (error) {
      await store.save({...state, failedJobs: (state.failedJobs ?? 0) + 1, lastErrorCode: error.code ?? 'SYNC_FAILED'});
      throw error;
    }
  });
} catch (error) {
  const code = error.code ?? error.message;
  console.error(JSON.stringify({status: 'error', code: /^[A-Z_]+$/.test(code) ? code : 'JOB_FAILED'}));
  process.exitCode = 1;
}

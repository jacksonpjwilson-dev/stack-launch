import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, readFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {randomBytes} from 'node:crypto';
import {EncryptedStateFile, synchronize, ProviderError, PlaidProvider} from './sync.mjs';
const state = () => ({itemID: 'synthetic-item', accessToken: 'synthetic-token', cursor: 'old', transactions: []});
const tx = (id, extras = {}) => ({transaction_id: id, account_id: 'synthetic-account', ...extras});
const page = (added, cursor, more = false, extras = {}) => ({added, modified: [], removed: [], next_cursor: cursor, has_more: more, ...extras});
test('pagination, incremental state and pending reconciliation', async () => {
  const initial = state(); initial.transactions = [tx('pending', {pending: true})];
  const calls = [];
  const result = await synchronize(initial, {page: async (_, cursor) => { calls.push(cursor); return cursor === 'old' ? page([tx('posted', {pending_transaction_id: 'pending', pending: false})], 'p1', true) : page([tx('other')], 'done'); }});
  assert.deepEqual(calls, ['old', 'p1']); assert.equal(result.cursor, 'done'); assert.deepEqual(result.transactions.map(t => t.transaction_id), ['posted', 'other']); assert.equal(initial.cursor, 'old');
});
test('modifications and removals are idempotent', async () => {
  const initial = state(); initial.transactions = [tx('one'), tx('remove')];
  const provider = {page: async () => page([], 'new', false, {modified: [tx('one', {amount: 4})], removed: [{transaction_id: 'remove'}]})};
  const result = await synchronize(initial, provider); const repeated = await synchronize(result, provider);
  assert.equal(repeated.transactions.length, 1); assert.equal(repeated.transactions[0].amount, 4);
});
test('failed pagination leaves original state unchanged', async () => {
  const initial = state();
  await assert.rejects(synchronize(initial, {page: async (_, cursor) => { if (cursor === 'old') return page([tx('one')], 'next', true); throw new ProviderError('PRODUCT_NOT_READY'); }}));
  assert.equal(initial.cursor, 'old'); assert.equal(initial.transactions.length, 0);
});
test('mutation restarts from original cursor without partial data', async () => {
  let calls = [], failed = false;
  const result = await synchronize(state(), {page: async (_, cursor) => {
    calls.push(cursor);
    if (cursor === 'old') return page([tx(failed ? 'new' : 'obsolete')], 'next', true);
    if (!failed) { failed = true; throw new ProviderError('TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION'); }
    return page([], 'done');
  }});
  assert.deepEqual(calls, ['old', 'next', 'old', 'next']); assert.deepEqual(result.transactions.map(t => t.transaction_id), ['new']);
});
test('encrypted atomic state and single-writer lock', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'stack-test-'));
  try {
    const file = path.join(dir, 'state'), key = randomBytes(32), store = new EncryptedStateFile(file, key);
    await store.save(state()); assert.deepEqual(await store.load(), state()); assert.ok(!(await readFile(file, 'utf8')).includes('synthetic-token'));
    await store.exclusive(async () => { await assert.rejects(store.exclusive(async () => {}), /JOB_ALREADY/); });
    await assert.rejects(new EncryptedStateFile(file, randomBytes(32)).load(), /STATE_UNREADABLE/);
  } finally { await rm(dir, {recursive: true, force: true}); }
});
test('rate limit retries are bounded and provider payloads stay private', async () => {
  let calls = 0, waits = [];
  const provider = new PlaidProvider({clientID: 'synthetic', secret: 'synthetic', wait: async ms => waits.push(ms), fetchImpl: async () => { calls++; return new Response(JSON.stringify({error_code: 'RATE_LIMIT_EXCEEDED', error_message: 'sensitive message'}), {status: 429}); }});
  await assert.rejects(provider.page('synthetic-token', null), error => error.message === 'RATE_LIMIT_EXCEEDED'); assert.equal(calls, 4); assert.equal(waits.length, 3);
});

import {createCipheriv, createDecipheriv, randomBytes} from 'node:crypto';
import {mkdir, readFile, writeFile, rename, open, unlink} from 'node:fs/promises';
import path from 'node:path';

export class ProviderError extends Error {
  constructor(code, retryable = false) { super(code); this.code = code; this.retryable = retryable; }
}
export class PlaidProvider {
  constructor({clientID, secret, environment = 'sandbox', fetchImpl = fetch, wait = ms => new Promise(resolve => setTimeout(resolve, ms))}) {
    if (!['sandbox', 'production'].includes(environment) || !clientID || !secret) throw new Error('INVALID_CONFIGURATION');
    this.host = `https://${environment}.plaid.com`; this.clientID = clientID; this.secret = secret; this.fetch = fetchImpl; this.wait = wait;
  }
  async page(accessToken, cursor) {
    for (let attempt = 0; attempt < 4; attempt++) {
      let response;
      try {
        response = await this.fetch(this.host + '/transactions/sync', {method: 'POST', signal: AbortSignal.timeout(25000), headers: {'Content-Type': 'application/json'}, body: JSON.stringify({client_id: this.clientID, secret: this.secret, access_token: accessToken, ...(cursor ? {cursor} : {}), count: 500})});
      } catch {
        if (attempt === 3) throw new ProviderError('PROVIDER_UNAVAILABLE', true);
        await this.wait(500 * 2 ** attempt); continue;
      }
      let body;
      try { body = await response.json(); } catch { throw new ProviderError('INVALID_PROVIDER_RESPONSE'); }
      if (response.ok) return body;
      // Never propagate provider messages or payloads into logs or monitoring.
      const code = /^[A-Z_]+$/.test(body.error_code ?? '') ? body.error_code : 'PROVIDER_ERROR';
      const retryable = response.status === 429 || response.status >= 500;
      if (!retryable || attempt === 3) throw new ProviderError(code, retryable);
      const retryAfter = Number(response.headers.get('retry-after'));
      await this.wait(Number.isFinite(retryAfter) && retryAfter > 0 ? Math.min(retryAfter * 1000, 30000) : 500 * 2 ** attempt);
    }
  }
}
export class EncryptedStateFile {
  constructor(filename, key) {
    if (!Buffer.isBuffer(key) || key.length !== 32) throw new Error('INVALID_ENCRYPTION_KEY');
    this.filename = filename; this.key = key;
  }
  async load() {
    let data;
    try { data = JSON.parse(await readFile(this.filename, 'utf8')); } catch (error) { if (error.code === 'ENOENT') return null; throw new Error('STATE_UNREADABLE'); }
    try {
      const decipher = createDecipheriv('aes-256-gcm', this.key, Buffer.from(data.iv, 'base64'));
      decipher.setAuthTag(Buffer.from(data.tag, 'base64'));
      return JSON.parse(Buffer.concat([decipher.update(Buffer.from(data.body, 'base64')), decipher.final()]).toString('utf8'));
    } catch { throw new Error('STATE_UNREADABLE'); }
  }
  async save(state) {
    await mkdir(path.dirname(this.filename), {recursive: true, mode: 0o700});
    const iv = randomBytes(12), cipher = createCipheriv('aes-256-gcm', this.key, iv);
    const body = Buffer.concat([cipher.update(JSON.stringify(state)), cipher.final()]);
    const temporary = this.filename + '.' + randomBytes(8).toString('hex') + '.tmp';
    try {
      await writeFile(temporary, JSON.stringify({iv: iv.toString('base64'), tag: cipher.getAuthTag().toString('base64'), body: body.toString('base64')}), {mode: 0o600, flag: 'wx'});
      await rename(temporary, this.filename);
    } finally { await unlink(temporary).catch(() => {}); }
  }
  async exclusive(job) {
    await mkdir(path.dirname(this.filename), {recursive: true, mode: 0o700});
    let handle;
    try { handle = await open(this.filename + '.lock', 'wx', 0o600); }
    catch { throw new Error('JOB_ALREADY_RUNNING_OR_LOCK_REQUIRES_REVIEW'); }
    try { return await job(); } finally { await handle.close(); await unlink(this.filename + '.lock'); }
  }
}
export async function synchronize(state, provider, now = () => new Date().toISOString()) {
  if (!state?.accessToken || !state.itemID) throw new Error('ITEM_NOT_CONFIGURED');
  const initialCursor = state.cursor;
  // A mutation during pagination requires restarting the whole batch at the ORIGINAL cursor.
  for (let restart = 0; restart < 3; restart++) {
    const staged = structuredClone(state), transactions = new Map((state.transactions ?? []).map(t => [t.transaction_id, t]));
    let cursor = initialCursor, seen = new Set();
    try {
      for (let pageNumber = 0; pageNumber < 1000; pageNumber++) {
        const page = await provider.page(state.accessToken, cursor);
        if (!Array.isArray(page.added) || !Array.isArray(page.modified) || !Array.isArray(page.removed) || typeof page.has_more !== 'boolean' || typeof page.next_cursor !== 'string' || (page.has_more && (!page.next_cursor || seen.has(page.next_cursor) || page.next_cursor === cursor)) || (!page.next_cursor && (page.added.length || page.modified.length || page.removed.length))) throw new Error('INVALID_SYNC_PAGE');
        seen.add(page.next_cursor);
        for (const transaction of [...page.added, ...page.modified]) {
          if (!transaction.transaction_id || !transaction.account_id) throw new Error('INVALID_TRANSACTION');
          transactions.set(transaction.transaction_id, transaction);
          if (!transaction.pending && transaction.pending_transaction_id) transactions.delete(transaction.pending_transaction_id);
        }
        for (const removed of page.removed) transactions.delete(removed.transaction_id);
        cursor = page.next_cursor || cursor;
        if (!page.has_more) return {...staged, transactions: [...transactions.values()], cursor, lastSuccess: now(), failedJobs: 0};
      }
      throw new Error('PAGINATION_LIMIT');
    } catch (error) {
      if (error.code === 'TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION' && restart < 2) continue;
      throw error;
    }
  }
}

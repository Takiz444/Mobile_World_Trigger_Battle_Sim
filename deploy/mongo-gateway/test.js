// Gateway tests against a real mongod (mongodb-memory-server downloads one).
//   cd deploy/mongo-gateway && npm ci && npm test
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { MongoMemoryServer } = require('mongodb-memory-server');
const { start } = require('./server');

const TOKEN = 'test-token-0123456789';
let mongod;
let gw;
let base;

async function call(method, path, body, token = TOKEN) {
  const res = await fetch(base + path, {
    method,
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return { status: res.status, body: await res.json() };
}

test.before(async () => {
  mongod = await MongoMemoryServer.create({ instance: { launchTimeout: 120000 } });
  gw = await start({ MONGO_URI: mongod.getUri(), MONGO_DB: 'trion_test', GATEWAY_PORT: '0', GATEWAY_TOKEN: TOKEN });
  base = `http://127.0.0.1:${gw.port}`;
});

test.after(async () => {
  if (gw) await gw.close();
  if (mongod) await mongod.stop();
});

test('health pings the database and requires the token', async () => {
  assert.equal((await call('GET', '/health')).status, 200);
  assert.equal((await call('GET', '/health', undefined, 'wrong')).status, 401);
  assert.equal((await call('GET', '/health', undefined, '')).status, 401);
});

test('records round-trip, stored flat with _id', async () => {
  const doc = { id: 'p1', name: 'Osamu', email: 'osamu@example.com', trophies: 30,
    history: [{ result: 'win', top_move: 'Asteroid' }], move_counts: { Asteroid: 4, 'Lead Bullet': 1 } };
  const put = await call('POST', '/batch', { ops: [{ op: 'put', kind: 'accounts', id: 'p1', doc }] });
  assert.deepEqual(put.body, { ok: true, failed: [] });
  const got = await call('GET', '/records/accounts?limit=10');
  assert.equal(got.status, 200);
  assert.deepEqual(got.body.records, [{ id: 'p1', doc }]);
  assert.equal(got.body.next, null);
});

test('later puts replace, deletes remove', async () => {
  await call('POST', '/batch', { ops: [{ op: 'put', kind: 'meta', id: 'server', doc: { season: 1 } }] });
  await call('POST', '/batch', { ops: [{ op: 'put', kind: 'meta', id: 'server', doc: { season: 2 } }] });
  let got = await call('GET', '/records/meta');
  assert.deepEqual(got.body.records, [{ id: 'server', doc: { season: 2 } }]);
  await call('POST', '/batch', { ops: [{ op: 'delete', kind: 'meta', id: 'server' }] });
  got = await call('GET', '/records/meta');
  assert.deepEqual(got.body.records, []);
});

test('pages by id', async () => {
  const ops = [];
  for (let i = 0; i < 25; i++) {
    const id = `t${String(i).padStart(2, '0')}`;
    ops.push({ op: 'put', kind: 'tickets', id, doc: { ticket: id } });
  }
  await call('POST', '/batch', { ops });
  const seen = [];
  let after = '';
  for (;;) {
    const page = await call('GET', `/records/tickets?limit=10${after ? `&after=${after}` : ''}`);
    seen.push(...page.body.records.map((r) => r.id));
    if (!page.body.next) break;
    after = page.body.next;
  }
  assert.equal(seen.length, 25);
  assert.equal(new Set(seen).size, 25);
});

test('matches: finished ones before the cutoff are skipped', async () => {
  await call('POST', '/batch', { ops: [
    { op: 'put', kind: 'matches', id: 'live1', doc: { id: 'live1', winner: -1, ended_at: 0 } },
    { op: 'put', kind: 'matches', id: 'old1', doc: { id: 'old1', winner: 0, ended_at: 100 } },
    { op: 'put', kind: 'matches', id: 'new1', doc: { id: 'new1', winner: 1, ended_at: 5000 } },
  ] });
  const got = await call('GET', '/records/matches?ended_after=1000');
  assert.deepEqual(got.body.records.map((r) => r.id).sort(), ['live1', 'new1']);
  const all = await call('GET', '/records/matches');
  assert.equal(all.body.records.length, 3);
});

test('a refused document is reported; the rest of the batch still applies', async () => {
  const res = await call('POST', '/batch', { ops: [
    { op: 'put', kind: 'accounts', id: 'p2', doc: { id: 'p2', email: 'osamu@example.com' } },   // duplicate email
    { op: 'put', kind: 'accounts', id: 'p3', doc: { id: 'p3', email: 'yuma@example.com' } },
    { op: 'put', kind: 'accounts', id: 'g1', doc: { id: 'g1', email: '' } },   // guests have no email
    { op: 'put', kind: 'accounts', id: 'g2', doc: { id: 'g2', email: '' } },
    { op: 'put', kind: 'nope', id: 'x', doc: {} },
    { op: 'put', kind: 'accounts', id: '../x', doc: {} },
  ] });
  assert.equal(res.status, 200);
  assert.deepEqual(res.body.failed.map((f) => f.index).sort(), [0, 4, 5]);
  const ids = (await call('GET', '/records/accounts')).body.records.map((r) => r.id).sort();
  assert.deepEqual(ids, ['g1', 'g2', 'p1', 'p3']);
});

test('bad requests', async () => {
  assert.equal((await call('GET', '/records/secrets')).status, 404);
  assert.equal((await call('GET', '/records/accounts?after=$gt')).status, 400);
  assert.equal((await call('POST', '/batch', { ops: 'x' })).status, 400);
});

test('import-dir moves a file store into MongoDB (and can be re-run)', async () => {
  const fs = require('node:fs');
  const os = require('node:os');
  const path = require('node:path');
  const { MongoClient } = require('mongodb');
  const { importDir } = require('./import-dir');
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'trion-store-'));
  for (const kind of ['accounts', 'matches', 'meta']) fs.mkdirSync(path.join(root, kind));
  fs.writeFileSync(path.join(root, 'accounts', 'imp1.json'), JSON.stringify({ id: 'imp1', name: 'Kuga', trophies: 300 }));
  fs.writeFileSync(path.join(root, 'accounts', 'broken.json'), '{not json');
  fs.writeFileSync(path.join(root, 'matches', 'm1.json'), JSON.stringify({ id: 'm1', winner: -1 }));
  fs.writeFileSync(path.join(root, 'meta', 'server.json'), JSON.stringify({ season: 4 }));
  const client = new MongoClient(mongod.getUri());
  await client.connect();
  try {
    const skipped = [];
    const counts = await importDir(client.db('trion_test'), root, (m) => skipped.push(m));
    assert.deepEqual(counts, { accounts: 1, tickets: 0, matches: 1, meta: 1 });
    assert.equal(skipped.length, 1);
    await importDir(client.db('trion_test'), root, () => {});
  } finally {
    await client.close();
    fs.rmSync(root, { recursive: true, force: true });
  }
  const accounts = (await call('GET', '/records/accounts?limit=100')).body.records;
  assert.deepEqual(accounts.find((r) => r.id === 'imp1').doc, { id: 'imp1', name: 'Kuga', trophies: 300 });
  assert.deepEqual((await call('GET', '/records/meta')).body.records, [{ id: 'server', doc: { season: 4 } }]);
});

test('export-dir writes the file store layout; import-dir restores it', async () => {
  const fs = require('node:fs');
  const os = require('node:os');
  const path = require('node:path');
  const { MongoClient } = require('mongodb');
  const { exportDir } = require('./export-dir');
  const { importDir } = require('./import-dir');
  const out = fs.mkdtempSync(path.join(os.tmpdir(), 'trion-export-'));
  const client = new MongoClient(mongod.getUri());
  await client.connect();
  try {
    const counts = await exportDir(client.db('trion_test'), out);
    assert.ok(counts.accounts >= 1 && counts.meta === 1);
    const p1 = JSON.parse(fs.readFileSync(path.join(out, 'accounts', 'p1.json'), 'utf8'));
    assert.equal(p1.email, 'osamu@example.com');
    assert.equal(p1._id, undefined);
    const restored = await importDir(client.db('trion_restore'), out, () => {});
    assert.deepEqual(restored, counts);
    const back = await client.db('trion_restore').collection('accounts').findOne({ _id: 'p1' });
    assert.equal(back.name, 'Osamu');
  } finally {
    await client.close();
    fs.rmSync(out, { recursive: true, force: true });
  }
});

test('loadDeployEnv: file values fill gaps, TT_* names map, real env wins', () => {
  const fs = require('node:fs');
  const os = require('node:os');
  const path = require('node:path');
  const { loadDeployEnv } = require('./server');
  const file = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'trion-env-')), '.env');
  fs.writeFileSync(file, '# deploy/.env\nTT_MONGO_URI="mongodb+srv://u:p@h/?retryWrites=true&w=majority"\n'
    + 'TT_MONGO_DB=trion\nTT_MONGO_GATEWAY_TOKEN=abc\nTT_T_KEEP=file\n');
  const saved = { ...process.env };
  try {
    for (const k of ['MONGO_URI', 'MONGO_DB', 'GATEWAY_TOKEN', 'TT_MONGO_URI', 'TT_MONGO_DB', 'TT_MONGO_GATEWAY_TOKEN']) delete process.env[k];
    process.env.TT_T_KEEP = 'env';
    assert.equal(loadDeployEnv(file), file);
    assert.equal(process.env.MONGO_URI, 'mongodb+srv://u:p@h/?retryWrites=true&w=majority');
    assert.equal(process.env.MONGO_DB, 'trion');
    assert.equal(process.env.GATEWAY_TOKEN, 'abc');
    assert.equal(process.env.TT_T_KEEP, 'env');
    assert.equal(loadDeployEnv(file + '.missing'), null);
  } finally {
    for (const k of Object.keys(process.env)) if (!(k in saved)) delete process.env[k];
    Object.assign(process.env, saved);
  }
});

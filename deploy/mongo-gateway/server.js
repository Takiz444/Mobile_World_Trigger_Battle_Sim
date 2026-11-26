// Trion Mongo gateway: the game server's MongoDB access (server/db/mongo_store.gd).
//
// Godot has no MongoDB driver, so this small service uses the official Node
// driver and exposes the few operations the game's store needs over HTTP.
// It is internal plumbing, not a public API: bind it to 127.0.0.1 (the
// default) or keep it on a private network, and set GATEWAY_TOKEN.
//
// Each record kind is a collection; a record is stored as {_id: id, ...record}
// so it can be read and queried directly in mongosh / Atlas.
//
// Environment:
//   MONGO_URI        mongodb:// or mongodb+srv:// connection string (required)
//   MONGO_DB         database name (default "trion")
//   GATEWAY_HOST     listen address (default 127.0.0.1)
//   GATEWAY_PORT     listen port (default 8095)
//   GATEWAY_TOKEN    shared secret the game server sends as a Bearer token
//                    (required unless GATEWAY_HOST is a loopback address)
//
// Run by hand (npm start / npm run dev), it also reads deploy/.env, the same
// file the game server reads: TT_MONGO_URI, TT_MONGO_DB and
// TT_MONGO_GATEWAY_TOKEN stand in for the three settings above. Real
// environment variables win. (Docker and the VM pass the environment directly.)
//
// API:
//   GET  /health
//   GET  /records/:kind?limit=N&after=<id>[&ended_after=<unix>]  -> {records: [{id, doc}], next}
//   POST /batch {ops: [{op: "put"|"delete", kind, id, doc?}]}     -> {ok, failed: [{index, error}]}
'use strict';

const http = require('node:http');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const util = require('node:util');
const { MongoClient, MongoBulkWriteError } = require('mongodb');

const KINDS = new Set(['accounts', 'tickets', 'matches', 'meta']);
const ID_RE = /^[A-Za-z0-9_]{1,64}$/;
const MAX_BODY = 64 * 1024 * 1024;
const MAX_PAGE = 1000;
const RESERVED = new Set(['_id', '_updated_at']);

// Reads deploy/.env (or `file`) into process.env without overriding what is
// set, then maps the game's TT_* names onto the gateway's. Returns the path
// read, or null if there was no file.
function loadDeployEnv(file = process.env.TT_ENV_FILE || path.join(__dirname, '..', '.env')) {
  let read = null;
  if (fs.existsSync(file)) {
    const parsed = util.parseEnv(fs.readFileSync(file, 'utf8'));
    for (const [k, v] of Object.entries(parsed)) {
      if (process.env[k] === undefined) process.env[k] = v;
    }
    read = file;
  }
  const alias = { MONGO_URI: 'TT_MONGO_URI', MONGO_DB: 'TT_MONGO_DB', GATEWAY_TOKEN: 'TT_MONGO_GATEWAY_TOKEN' };
  for (const [name, tt] of Object.entries(alias)) {
    if (!process.env[name] && process.env[tt]) process.env[name] = process.env[tt];
  }
  return read;
}

function loopback(host) {
  return host === '127.0.0.1' || host === '::1' || host === 'localhost';
}

function sameSecret(a, b) {
  const ha = crypto.createHash('sha256').update(String(a)).digest();
  const hb = crypto.createHash('sha256').update(String(b)).digest();
  return crypto.timingSafeEqual(ha, hb);
}

function send(res, status, body) {
  const data = JSON.stringify(body);
  res.writeHead(status, {
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(data),
    'Cache-Control': 'no-store',
  });
  res.end(data);
}

function readJson(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > MAX_BODY) {
        reject(Object.assign(new Error('body too large'), { status: 413 }));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => {
      try {
        resolve(chunks.length ? JSON.parse(Buffer.concat(chunks).toString('utf8')) : {});
      } catch {
        reject(Object.assign(new Error('invalid JSON'), { status: 400 }));
      }
    });
    req.on('error', reject);
  });
}

// A record as stored: the game's fields at the top level, keyed by _id.
function toDocument(id, doc) {
  const out = { _id: id };
  for (const [k, v] of Object.entries(doc)) {
    if (!RESERVED.has(k)) out[k] = v;
  }
  out._updated_at = new Date();
  return out;
}

function fromDocument(d) {
  const { _id, _updated_at, ...doc } = d;
  return { id: String(_id), doc };
}

async function ensureIndexes(db) {
  const accounts = db.collection('accounts');
  // Sign-in looks accounts up by email: unique, and only for accounts that have one.
  await accounts.createIndex({ email: 1 }, {
    name: 'email_unique',
    unique: true,
    partialFilterExpression: { email: { $type: 'string', $gt: '' } },
  });
  await accounts.createIndex({ trophies: -1, rating: -1 }, { name: 'ladder' });
  await db.collection('matches').createIndex({ winner: 1, ended_at: 1 }, { name: 'finished' });
}

function createGateway({ db, token }) {
  async function loadPage(kind, url) {
    const limit = Math.min(Math.max(parseInt(url.searchParams.get('limit') || '500', 10) || 500, 1), MAX_PAGE);
    const filter = {};
    const after = url.searchParams.get('after');
    if (after) {
      if (!ID_RE.test(after)) throw Object.assign(new Error('bad cursor'), { status: 400 });
      filter._id = { $gt: after };
    }
    const endedAfter = url.searchParams.get('ended_after');
    if (kind === 'matches' && endedAfter !== null) {
      // Unfinished matches, plus ones that ended inside the retention window.
      const cutoff = Number(endedAfter);
      if (!Number.isFinite(cutoff)) throw Object.assign(new Error('bad ended_after'), { status: 400 });
      filter.$or = [{ winner: -1 }, { winner: { $exists: false } }, { ended_at: { $gte: cutoff } }];
    }
    const docs = await db.collection(kind).find(filter).sort({ _id: 1 }).limit(limit).toArray();
    const records = docs.map(fromDocument);
    const next = docs.length === limit ? String(docs[docs.length - 1]._id) : null;
    return { records, next };
  }

  async function applyBatch(ops) {
    if (!Array.isArray(ops)) throw Object.assign(new Error('ops must be an array'), { status: 400 });
    const failed = [];
    const byKind = new Map();   // kind -> [{index, model}]
    ops.forEach((op, index) => {
      if (!op || typeof op !== 'object' || !KINDS.has(op.kind) || !ID_RE.test(String(op.id))) {
        failed.push({ index, error: 'invalid op' });
        return;
      }
      let model;
      if (op.op === 'put' && op.doc && typeof op.doc === 'object' && !Array.isArray(op.doc)) {
        model = { replaceOne: { filter: { _id: op.id }, replacement: toDocument(op.id, op.doc), upsert: true } };
      } else if (op.op === 'delete') {
        model = { deleteOne: { filter: { _id: op.id } } };
      } else {
        failed.push({ index, error: 'invalid op' });
        return;
      }
      if (!byKind.has(op.kind)) byKind.set(op.kind, []);
      byKind.get(op.kind).push({ index, model });
    });
    for (const [kind, items] of byKind) {
      try {
        await db.collection(kind).bulkWrite(items.map((i) => i.model), { ordered: false });
      } catch (err) {
        // Per-document refusals (e.g. a duplicate email) are reported and
        // dropped by the client; anything else fails the batch, to be retried.
        if (!(err instanceof MongoBulkWriteError) || !err.writeErrors) throw err;
        const errors = Array.isArray(err.writeErrors) ? err.writeErrors : Object.values(err.writeErrors);
        if (errors.length === 0) throw err;
        for (const we of errors) {
          const item = items[we.index];
          if (item) failed.push({ index: item.index, error: `${we.code}: ${we.errmsg || we.message || 'write error'}` });
        }
      }
    }
    return { ok: true, failed };
  }

  return async function handle(req, res) {
    try {
      if (token && !sameSecret((req.headers.authorization || '').replace(/^Bearer\s+/i, ''), token)) {
        return send(res, 401, { error: 'unauthorized' });
      }
      const url = new URL(req.url, 'http://gateway');
      const parts = url.pathname.split('/').filter(Boolean);
      if (req.method === 'GET' && url.pathname === '/health') {
        await db.command({ ping: 1 });
        return send(res, 200, { ok: true });
      }
      if (req.method === 'GET' && parts.length === 2 && parts[0] === 'records' && KINDS.has(parts[1])) {
        return send(res, 200, await loadPage(parts[1], url));
      }
      if (req.method === 'POST' && url.pathname === '/batch') {
        const body = await readJson(req);
        return send(res, 200, await applyBatch(body.ops));
      }
      return send(res, 404, { error: 'not found' });
    } catch (err) {
      const status = err.status || 503;
      if (status >= 500) console.error('gateway error:', err.message);
      return send(res, status, { error: err.message || 'error' });
    }
  };
}

async function start(env = process.env) {
  const uri = env.MONGO_URI;
  const host = env.GATEWAY_HOST || '127.0.0.1';
  const port = parseInt(env.GATEWAY_PORT || '8095', 10);
  const token = env.GATEWAY_TOKEN || '';
  if (!uri) throw new Error('MONGO_URI is not set');
  if (!token && !loopback(host)) throw new Error('GATEWAY_TOKEN is required when listening beyond loopback');
  const client = new MongoClient(uri, { appName: 'trion-gateway', serverSelectionTimeoutMS: 10000 });
  await client.connect();
  const db = client.db(env.MONGO_DB || 'trion');
  await ensureIndexes(db);
  const server = http.createServer(createGateway({ db, token }));
  server.requestTimeout = 60000;
  await new Promise((resolve) => server.listen(port, host, resolve));
  console.log(`Trion Mongo gateway on ${host}:${server.address().port}, database ${db.databaseName}`);
  return {
    server,
    port: server.address().port,
    close: async () => {
      await new Promise((resolve) => server.close(resolve));
      await client.close();
    },
  };
}

module.exports = { start, createGateway, toDocument, fromDocument, ensureIndexes, loadDeployEnv };

if (require.main === module) {
  const envFile = loadDeployEnv();
  if (envFile) console.log(`Read settings from ${envFile}`);
  start().then((gw) => {
    const stop = () => gw.close().finally(() => process.exit(0));
    process.on('SIGTERM', stop);
    process.on('SIGINT', stop);
  }).catch((err) => {
    console.error(`Mongo gateway failed to start: ${err.message}`);
    process.exit(1);
  });
}

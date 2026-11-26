// Imports a file store (TT_STORE=dir: <store>/<kind>/<id>.json, e.g.
// /var/lib/trion/store) into MongoDB, so a running deployment can move to
// TT_STORE=mongo without losing accounts or matches. Safe to re-run: every
// record is upserted by id. Stop the game server first so nothing changes
// underneath.
//   MONGO_URI='mongodb+srv://...' MONGO_DB=trion node import-dir.js /var/lib/trion/store
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { MongoClient } = require('mongodb');
const { toDocument, ensureIndexes } = require('./server');

const KINDS = ['accounts', 'tickets', 'matches', 'meta'];
const ID_RE = /^[A-Za-z0-9_]{1,64}$/;
const CHUNK = 200;

// Returns {kind: count imported}; unreadable files are reported and skipped.
async function importDir(db, root, log = console.log) {
  await ensureIndexes(db);
  const counts = {};
  for (const kind of KINDS) {
    counts[kind] = 0;
    const dir = path.join(root, kind);
    if (!fs.existsSync(dir)) continue;
    let ops = [];
    const flush = async () => {
      if (ops.length) await db.collection(kind).bulkWrite(ops, { ordered: false });
      counts[kind] += ops.length;
      ops = [];
    };
    for (const file of fs.readdirSync(dir).sort()) {
      if (!file.endsWith('.json')) continue;
      const id = file.slice(0, -5);
      let doc;
      try {
        doc = JSON.parse(fs.readFileSync(path.join(dir, file), 'utf8'));
      } catch (err) {
        log(`skipping ${kind}/${file}: ${err.message}`);
        continue;
      }
      if (!ID_RE.test(id) || !doc || typeof doc !== 'object' || Array.isArray(doc)) {
        log(`skipping ${kind}/${file}: not a record`);
        continue;
      }
      ops.push({ replaceOne: { filter: { _id: id }, replacement: toDocument(id, doc), upsert: true } });
      if (ops.length >= CHUNK) await flush();
    }
    await flush();
  }
  return counts;
}

module.exports = { importDir };

if (require.main === module) {
  const root = process.argv[2];
  if (!root || !process.env.MONGO_URI) {
    console.error('usage: MONGO_URI=... [MONGO_DB=trion] node import-dir.js <store dir>');
    process.exit(2);
  }
  (async () => {
    const client = new MongoClient(process.env.MONGO_URI, { appName: 'trion-import' });
    await client.connect();
    try {
      const counts = await importDir(client.db(process.env.MONGO_DB || 'trion'), root);
      console.log('imported', counts);
    } finally {
      await client.close();
    }
  })().catch((err) => {
    console.error(`import failed: ${err.message}`);
    process.exit(1);
  });
}

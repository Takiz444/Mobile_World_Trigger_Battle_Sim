// Exports MongoDB to the file store layout (<out>/<kind>/<id>.json): a backup
// that import-dir.js can restore, or that the game can run on directly with
// TT_STORE=dir. deploy/native/install.sh runs it daily when TT_STORE=mongo
// (Atlas's free tier has no automated backups).
//   MONGO_URI='mongodb+srv://...' MONGO_DB=trion node export-dir.js /tmp/trion-export
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { MongoClient } = require('mongodb');
const { fromDocument } = require('./server');

const KINDS = ['accounts', 'tickets', 'matches', 'meta'];
const ID_RE = /^[A-Za-z0-9_]{1,64}$/;

// Returns {kind: count exported}.
async function exportDir(db, out) {
  const counts = {};
  for (const kind of KINDS) {
    const dir = path.join(out, kind);
    fs.mkdirSync(dir, { recursive: true });
    counts[kind] = 0;
    for await (const d of db.collection(kind).find({}).sort({ _id: 1 })) {
      const { id, doc } = fromDocument(d);
      if (!ID_RE.test(id)) continue;
      fs.writeFileSync(path.join(dir, `${id}.json`), JSON.stringify(doc));
      counts[kind] += 1;
    }
  }
  return counts;
}

module.exports = { exportDir };

if (require.main === module) {
  const out = process.argv[2];
  if (!out || !process.env.MONGO_URI) {
    console.error('usage: MONGO_URI=... [MONGO_DB=trion] node export-dir.js <out dir>');
    process.exit(2);
  }
  (async () => {
    const client = new MongoClient(process.env.MONGO_URI, { appName: 'trion-export' });
    await client.connect();
    try {
      console.log('exported', await exportDir(client.db(process.env.MONGO_DB || 'trion'), out));
    } finally {
      await client.close();
    }
  })().catch((err) => {
    console.error(`export failed: ${err.message}`);
    process.exit(1);
  });
}

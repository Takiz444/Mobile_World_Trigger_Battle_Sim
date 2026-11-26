// Local development / CI: a throwaway in-memory MongoDB plus the gateway, so
// the game server can run with TT_STORE=mongo without installing MongoDB.
//   cd deploy/mongo-gateway && npm ci && npm run dev
// then, in another terminal (Git Bash):
//   TT_STORE=mongo TT_MONGO_GATEWAY_URL=http://127.0.0.1:8095 TT_MONGO_GATEWAY_TOKEN=dev-token \
//     godot --headless --path . res://server/server.tscn
// Data is gone when this stops. Use GATEWAY_PORT / GATEWAY_TOKEN to change them.
'use strict';

const { MongoMemoryServer } = require('mongodb-memory-server');
const { start, loadDeployEnv } = require('./server');

(async () => {
  // The token comes from deploy/.env (TT_MONGO_GATEWAY_TOKEN) when there is
  // one, so it matches what the game server sends. MONGO_URI is ignored here:
  // this is always a throwaway database.
  loadDeployEnv();
  const mongod = await MongoMemoryServer.create({ instance: { launchTimeout: 120000 } });
  const gw = await start({
    MONGO_URI: mongod.getUri(),
    MONGO_DB: 'trion_dev',
    GATEWAY_PORT: process.env.GATEWAY_PORT || '8095',
    GATEWAY_TOKEN: process.env.GATEWAY_TOKEN || 'dev-token',
  });
  console.log('ready');
  const stop = async () => {
    await gw.close();
    await mongod.stop();
    process.exit(0);
  };
  process.on('SIGTERM', stop);
  process.on('SIGINT', stop);
})().catch((err) => {
  console.error(err);
  process.exit(1);
});

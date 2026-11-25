# The Mongo gateway (server.js): MongoDB access for the game server.
# Built by deploy/docker-compose.yml (profiles "mongo" and "atlas").
#   docker build -t trion-mongo-gateway deploy/mongo-gateway
FROM node:22-alpine
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund && npm cache clean --force
COPY server.js import-dir.js export-dir.js ./
USER node
ENV GATEWAY_HOST=0.0.0.0 GATEWAY_PORT=8095
EXPOSE 8095
HEALTHCHECK --interval=15s --timeout=5s --retries=4 \
	CMD wget -q -O /dev/null --header "Authorization: Bearer $GATEWAY_TOKEN" http://127.0.0.1:8095/health || exit 1
CMD ["node", "server.js"]

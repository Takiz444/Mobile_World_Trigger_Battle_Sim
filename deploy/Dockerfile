# Headless Trion Tactics game server (REST :8080 + live WebSocket :8081).
#
# Build from the repo root:
#   docker build -f deploy/Dockerfile -t trion-server .
# Run (data persists in the named volume):
#   docker run -p 8080:8080 -p 8081:8081 -v trion-data:/data trion-server
#
# In production use deploy/docker-compose.yml, which puts Caddy in front for
# HTTPS/WSS (iOS App Transport Security rejects plain http:// and ws://).

FROM debian:bookworm-slim

ARG GODOT_VERSION=4.7.2
RUN apt-get update \
	&& apt-get install -y --no-install-recommends ca-certificates curl unzip libfontconfig1 \
	&& rm -rf /var/lib/apt/lists/*
RUN curl -fsSL -o /tmp/godot.zip \
		"https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable/Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip" \
	&& unzip /tmp/godot.zip -d /tmp/godot \
	&& mv /tmp/godot/Godot_v${GODOT_VERSION}-stable_linux.x86_64 /usr/local/bin/godot \
	&& chmod +x /usr/local/bin/godot \
	&& rm -rf /tmp/godot /tmp/godot.zip

RUN useradd --create-home --uid 10001 trion && mkdir -p /data /app && chown trion /data /app
WORKDIR /app
COPY --chown=trion . .
USER trion

# Import once so every class_name is registered before the server starts.
RUN godot --headless --editor --quit --path /app

ENV TT_PORT=8080 \
	TT_LIVE_PORT=8081 \
	TT_DATA_FILE=/data/matches.json
EXPOSE 8080 8081
VOLUME /data

CMD ["godot", "--headless", "--path", "/app", "res://server/server.tscn"]

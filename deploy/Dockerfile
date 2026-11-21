# Two images from one file (both built by deploy/docker-compose.yml):
#
#   server  Headless Trion Tactics game server (REST :8080 + live WebSocket :8081).
#   web     Caddy with the exported Web client baked in: it serves the game at
#           https://$TT_DOMAIN/ and proxies the API and /live to `server`, so
#           the browser talks to a single HTTPS origin (no CORS).
#
# Works on x86-64 and ARM64 hosts (e.g. Oracle Cloud's free Ampere VMs).
#
# Build the server alone from the repo root:
#   docker build -f deploy/Dockerfile --target server -t trion-server .
# Run (data persists in the named volume):
#   docker run -p 8080:8080 -p 8081:8081 -v trion-data:/data trion-server
#
# In production use deploy/docker-compose.yml, which puts Caddy in front for
# HTTPS/WSS (iOS App Transport Security rejects plain http:// and ws://).

# ---------------------------------------------------------------- godot base
FROM debian:bookworm-slim AS godot

ARG GODOT_VERSION=4.7.2
# Set by BuildKit / docker compose: amd64 or arm64.
ARG TARGETARCH
# SHA-512s from SHA512-SUMS.txt on the Godot release page. A download that
# doesn't match fails the build.
ARG GODOT_SHA512_X86_64=9aa00f7a605200940bce3027a567b782f49bd8e940dd06ae9e987bd65aee1b1467edd56ed84fcdcbdd44354bf613bdbb4e5d2913e925850368e150c59ed54c65
ARG GODOT_SHA512_ARM64=dd59918da086bd49bde2f5450b5e567ff8650cbde9abbd7b8f4ca1197ff8c609baa38834666d032deafb47099078d7822279e2a0e06e5665745468f26533e7e2
RUN apt-get update \
	&& apt-get install -y --no-install-recommends ca-certificates curl unzip libfontconfig1 \
	&& rm -rf /var/lib/apt/lists/*
RUN set -eu; \
	case "${TARGETARCH:-amd64}" in \
		amd64) arch=x86_64; sum="$GODOT_SHA512_X86_64" ;; \
		arm64) arch=arm64; sum="$GODOT_SHA512_ARM64" ;; \
		*) echo "unsupported architecture: $TARGETARCH" >&2; exit 1 ;; \
	esac; \
	curl -fsSL -o /tmp/godot.zip \
		"https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable/Godot_v${GODOT_VERSION}-stable_linux.${arch}.zip"; \
	echo "$sum  /tmp/godot.zip" | sha512sum -c -; \
	unzip /tmp/godot.zip -d /tmp/godot; \
	mv /tmp/godot/Godot_v${GODOT_VERSION}-stable_linux.${arch} /usr/local/bin/godot; \
	chmod +x /usr/local/bin/godot; \
	rm -rf /tmp/godot /tmp/godot.zip

# ------------------------------------------------------------- web export
FROM godot AS webexport
ARG GODOT_VERSION=4.7.2
RUN apt-get update \
	&& apt-get install -y --no-install-recommends python3 \
	&& rm -rf /var/lib/apt/lists/*
COPY deploy/fetch_web_templates.py /tmp/fetch_web_templates.py
RUN python3 /tmp/fetch_web_templates.py "$GODOT_VERSION" \
		"/root/.local/share/godot/export_templates/${GODOT_VERSION}.stable"
WORKDIR /app
COPY . .
# Import, then export with the "Web" preset (export_presets.cfg). Release
# builds only talk HTTPS/WSS, to the origin that served them (ServerConfig).
RUN godot --headless --editor --quit --path /app \
	&& mkdir -p /out \
	&& godot --headless --path /app --export-release "Web" /out/index.html \
	&& test -s /out/index.wasm \
	&& gzip -k -9 /out/*.wasm /out/*.pck /out/*.js /out/*.html

# ------------------------------------------------------------------ web
FROM caddy:2.8 AS web
COPY --from=webexport /out /srv/web

# --------------------------------------------------------------- server
# Last stage, so a plain `docker build` still produces the server image.
FROM godot AS server

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
HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=4 \
	CMD curl -fsS "http://127.0.0.1:${TT_PORT}/health" || exit 1
VOLUME /data

CMD ["godot", "--headless", "--path", "/app", "res://server/server.tscn"]

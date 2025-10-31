#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Konfiguracja & sanity checks
# ──────────────────────────────────────────────────────────────────────────────
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "${ROOT_DIR}/.env" ]]; then
  echo "❌ Brak pliku .env w ${ROOT_DIR}. Najpierw uruchom zwykły start-local.sh lub utwórz .env."
  exit 1
fi

# Załaduj .env (nie eksportujemy wszystkiego na stałe)
set -a
source "${ROOT_DIR}/.env"
set +a

: "${ES_LOCAL_PORT:=9200}"
: "${KIBANA_LOCAL_PORT:=5601}"
: "${ES_LOCAL_PASSWORD:?Brakuje ES_LOCAL_PASSWORD w .env}"
: "${ES_LOCAL_VERSION:=9.2.0}"     # domyślna; możesz nadpisać w .env
: "${FLEET_SERVER_PORT:=8220}"

if [[ -z "${FLEET_SERVER_SERVICE_TOKEN:-}" ]]; then
  echo "❌ Brakuje FLEET_SERVER_SERVICE_TOKEN w .env — wklej service token z Kibany do .env i uruchom ponownie."
  exit 1
fi

# ──────────────────────────────────────────────────────────────────────────────
# 1) Wystaw porty ES/Kibana na 0.0.0.0 (zamiast 127.0.0.1)
# ──────────────────────────────────────────────────────────────────────────────
if [[ -f "${ROOT_DIR}/docker-compose.yml" ]]; then
  sed -i -E \
    -e "s#127\.0\.0\.1:\$\{ES_LOCAL_PORT\}:9200#0.0.0.0:\${ES_LOCAL_PORT}:9200#g" \
    -e "s#127\.0\.0\.1:\$\{KIBANA_LOCAL_PORT\}:5601#0.0.0.0:\${KIBANA_LOCAL_PORT}:5601#g" \
    -e "s#127\.0\.0\.1:(${ES_LOCAL_PORT}):9200#0.0.0.0:\1:9200#g" \
    -e "s#127\.0\.0\.1:(${KIBANA_LOCAL_PORT}):5601#0.0.0.0:\1:5601#g" \
    "${ROOT_DIR}/docker-compose.yml" || true
fi

# ──────────────────────────────────────────────────────────────────────────────
# 2) Utwórz/odśwież docker-compose.override.yml z fleet-server (DEV/HTTP)
# ──────────────────────────────────────────────────────────────────────────────
cat > "${ROOT_DIR}/docker-compose.override.yml" <<'YAML'
services:
  fleet-server:
    image: docker.elastic.co/elastic-agent/elastic-agent:${ES_LOCAL_VERSION}
    container_name: fleet-server
    depends_on:
      - elasticsearch
      - kibana
    ports:
      - 0.0.0.0:${FLEET_SERVER_PORT}:8220
    environment:
      - FLEET_SERVER_ENABLE=1
      - FLEET_SERVER_ELASTICSEARCH_HOST=http://elasticsearch:9200
      - FLEET_SERVER_SERVICE_TOKEN=${FLEET_SERVER_SERVICE_TOKEN}
      - FLEET_SERVER_INSECURE_HTTP=1
      # automatyczny setup Fleet w Kibanie:
      - KIBANA_FLEET_SETUP=1
      - KIBANA_FLEET_HOST=http://kibana:5601
      - KIBANA_FLEET_USERNAME=elastic
      - KIBANA_FLEET_PASSWORD=${ES_LOCAL_PASSWORD}
YAML

# Usuń ewentualną starą linię "version:" z override (Compose v2 i tak ignoruje)
sed -i '/^version:/d' "${ROOT_DIR}/docker-compose.override.yml" || true

# ──────────────────────────────────────────────────────────────────────────────
# 3) Uruchomienie
# ──────────────────────────────────────────────────────────────────────────────
echo "▶️  docker compose pull (obrazy elasticsearch, kibana, elastic-agent)…"
docker compose pull || true

echo "▶️  docker compose up -d (elasticsearch, kibana, fleet-server)…"
docker compose up -d

echo "⏳ Czekam chwilę i sprawdzam status usług…"
sleep 4
docker ps

echo "ℹ️  Test statusu Fleet Server (HTTP/dev):"
set +e
curl -fsS "http://localhost:${FLEET_SERVER_PORT}/api/status" || true
set -e

echo "✅ Gotowe. ES: 0.0.0.0:${ES_LOCAL_PORT}, Kibana: 0.0.0.0:${KIBANA_LOCAL_PORT}, Fleet: 0.0.0.0:${FLEET_SERVER_PORT}"

#!/usr/bin/env bash
# End-to-end checks of a built plugin against real RabbitMQ nodes in Docker.
#
#   scripts/build.sh && scripts/smoke-test.sh
#
# 1. A message published with x-delay=3000 is delivered after 3 s, not before.
# 2. A delayed message survives a node restart.
# 3. A message delayed by RabbitMQ 4.2.x with the upstream 4.2.0 plugin is delivered
#    after the node is upgraded to 4.3.x with this build.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_DIR="$(ls -d "$ROOT"/dist/rabbitmq_delayed_message_exchange-*/ | head -1)"
RABBITMQ_IMAGE="${RABBITMQ_IMAGE:-rabbitmq:4.3.6-management}"
OLD_RABBITMQ_IMAGE="${OLD_RABBITMQ_IMAGE:-rabbitmq:4.2.9-management}"
UPSTREAM_PLUGIN_URL="https://github.com/rabbitmq/rabbitmq-delayed-message-exchange/releases/download/v4.2.0/rabbitmq_delayed_message_exchange-4.2.0.ez"
PORT=25690
WORK="$(mktemp -d)"
NODE_HOSTNAME=dmx-smoke

cleanup() {
	docker rm -f dmx-smoke >/dev/null 2>&1 || true
	docker volume rm -f dmx-smoke-data >/dev/null 2>&1 || true
	rm -rf "$WORK"
}
trap cleanup EXIT

echo "[rabbitmq_management,rabbitmq_delayed_message_exchange]." >"$WORK/enabled_plugins"
curl -sSfL -o "$WORK/rabbitmq_delayed_message_exchange-4.2.0.ez" "$UPSTREAM_PLUGIN_URL"
docker volume create dmx-smoke-data >/dev/null
docker run --rm -v dmx-smoke-data:/data alpine chown 999:999 /data

# RabbitMQ runs as uid 999 so the image never needs to write /etc/rabbitmq.
start_node() {
	local image="$1" plugin_mount="$2"
	docker rm -f dmx-smoke >/dev/null 2>&1 || true
	docker run -d --name dmx-smoke --hostname "$NODE_HOSTNAME" --user 999:999 -p "$PORT:5672" \
		-e RABBITMQ_ENABLED_PLUGINS_FILE=/etc/rabbitmq-dmx/enabled_plugins \
		-v "$WORK/enabled_plugins:/etc/rabbitmq-dmx/enabled_plugins:ro" \
		-v "$plugin_mount" \
		-v dmx-smoke-data:/var/lib/rabbitmq \
		"$image" >/dev/null
	for _ in $(seq 1 90); do
		docker exec dmx-smoke rabbitmq-diagnostics -q check_port_connectivity >/dev/null 2>&1 && return 0
		docker ps -q --filter name=dmx-smoke | grep -q . || break
		sleep 1
	done
	docker logs dmx-smoke 2>&1 | tail -40
	echo "FAIL node did not start: $image" >&2
	exit 1
}

probe() {
	docker run --rm --network host -v "$ROOT/scripts/probe.py:/probe.py:ro" python:3.13-slim \
		sh -c "pip install -q pika==1.3.2 >/dev/null 2>&1 && python /probe.py $PORT $*"
}

this_build="$PLUGIN_DIR:/opt/rabbitmq/plugins/$(basename "$PLUGIN_DIR"):ro"
upstream_build="$WORK/rabbitmq_delayed_message_exchange-4.2.0.ez:/opt/rabbitmq/plugins/rabbitmq_delayed_message_exchange-4.2.0.ez:ro"

echo "== upgrade from $OLD_RABBITMQ_IMAGE with the upstream plugin"
start_node "$OLD_RABBITMQ_IMAGE" "$upstream_build"
probe publish from-4.2 20000
docker exec dmx-smoke rabbitmqctl -q enable_feature_flag all
docker stop dmx-smoke >/dev/null

start_node "$RABBITMQ_IMAGE" "$this_build"
probe expect from-4.2 20000 30

echo "== delivery after x-delay"
probe publish short 3000
probe expect short 3000 10

echo "== survives a restart"
probe publish restart 15000
docker restart dmx-smoke >/dev/null
start_node "$RABBITMQ_IMAGE" "$this_build"
probe expect restart 15000 25

echo "PASS"

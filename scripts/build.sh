#!/usr/bin/env bash
# Builds the plugin inside a rabbitmq-server checkout, in Docker, and writes the result to ./dist.
#
#   scripts/build.sh [rabbitmq tag] [elixir image]
#
# Build on the oldest Erlang/OTP the target RabbitMQ supports: modules compiled on OTP 27 load on
# OTP 27 and 28, modules compiled on OTP 28 do not load on 27.
set -euo pipefail

RABBITMQ_TAG="${1:-v4.3.6}"
BUILDER_IMAGE="${2:-elixir:1.20.4-otp-27}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

mkdir -p "$ROOT/dist"
docker run --rm \
	-v "$ROOT":/plugin:ro \
	-v "$ROOT/dist":/out \
	-e DEBIAN_FRONTEND=noninteractive \
	"$BUILDER_IMAGE" bash -euo pipefail -c "
		apt-get -qq update >/dev/null
		apt-get -qq install -y git rsync zip p7zip-full >/dev/null
		git clone -q --depth 1 --branch '$RABBITMQ_TAG' https://github.com/rabbitmq/rabbitmq-server.git /rmq 2>/dev/null
		rsync -a --exclude dist --exclude plugins --exclude ebin --exclude .git /plugin/ /rmq/deps/rabbitmq_delayed_message_exchange/
		cd /rmq/deps/rabbitmq_delayed_message_exchange
		make dist > /tmp/build.log 2>&1 || { tail -40 /tmp/build.log; exit 1; }
		rm -rf /out/*
		cp -r plugins/rabbitmq_delayed_message_exchange-* /out/
		ls /out
	"

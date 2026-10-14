"""Publishes or awaits one delayed message for scripts/smoke-test.sh.

python probe.py <port> publish <body> <delay ms>
python probe.py <port> expect <body> <delay ms> <timeout s>

`expect` exits 1 unless <body> arrives no earlier than <delay ms> after it was published.
"""
import json
import sys
import time

import pika

port, mode, body = int(sys.argv[1]), sys.argv[2], sys.argv[3]
delay = int(sys.argv[4])

connection = pika.BlockingConnection(pika.ConnectionParameters("localhost", port, connection_attempts=10, retry_delay=1))
channel = connection.channel()
channel.exchange_declare("smoke.delayed", "x-delayed-message", durable=True, arguments={"x-delayed-type": "fanout"})
channel.queue_declare("smoke.delayed.q", durable=True)
channel.queue_bind("smoke.delayed.q", "smoke.delayed")

if mode == "publish":
    channel.confirm_delivery()
    payload = json.dumps({"body": body, "published_at": time.time()})
    channel.basic_publish(
        "smoke.delayed",
        "",
        payload.encode(),
        pika.BasicProperties(delivery_mode=2, headers={"x-delay": delay}),
    )
    print(f"published {body} with x-delay={delay}")
    sys.exit(0)

deadline = time.time() + int(sys.argv[5])
while time.time() < deadline:
    method, _, content = channel.basic_get("smoke.delayed.q", auto_ack=True)
    if method is None:
        time.sleep(0.2)
        continue
    message = json.loads(content)
    waited_ms = (time.time() - message["published_at"]) * 1000
    if message["body"] != body:
        print(f"FAIL expected {body}, got {message['body']}")
        sys.exit(1)
    if waited_ms < delay:
        print(f"FAIL {body} arrived after {waited_ms:.0f} ms, before its x-delay of {delay} ms")
        sys.exit(1)
    print(f"ok {body} arrived after {waited_ms:.0f} ms (x-delay={delay})")
    sys.exit(0)
print(f"FAIL {body} did not arrive within {sys.argv[5]} s")
sys.exit(1)

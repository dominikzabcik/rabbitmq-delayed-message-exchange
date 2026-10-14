# RabbitMQ Delayed Message Plugin for RabbitMQ 4.3

A maintained fork of [rabbitmq/rabbitmq-delayed-message-exchange](https://github.com/rabbitmq/rabbitmq-delayed-message-exchange),
which Team RabbitMQ archived in 2026 after RabbitMQ 4.3 removed Mnesia from the broker.
The upstream 4.2.0 build fails to boot on 4.3 with `undef rabbit_mnesia:start_mnesia/1`.

This fork keeps the plugin working on **RabbitMQ 4.3.x** for people who still depend on
`x-delayed-message` exchanges while they move to something else. It changes as little as possible:

* The plugin starts OTP's own `mnesia` application as a node-local store instead of calling the
  `rabbit_mnesia` and `rabbit_table` modules that 4.3 removed.
* RabbitMQ 4.3 still points the `mnesia` directory at the node data directory, so delayed messages
  written by the upstream 4.2.0 plugin are delivered after the node is upgraded. The smoke test
  checks exactly that.
* The build moved to the RabbitMQ monorepo layout, in Docker, so it is reproducible.

The [limitations](#consider-the--limitations) of the original design still apply: delayed messages
live on one node, are not replicated, and are not meant for large volumes or long delays.

If you can, prefer the alternatives below. If you cannot yet, this fork buys you the time.

## Alternatives

* **Quorum queue delayed retry** (RabbitMQ 4.3+): `x-delayed-retry-type`, `x-delayed-retry-min` and
  `x-delayed-retry-max` delay redelivery of returned messages. Over AMQP 0-9-1 a `basic.nack` with
  `requeue=true` is delayed by `x-delayed-retry-min` every time, because 0-9-1 returns do not raise
  `delivery-count`. It covers retries with a fixed pause, not delays chosen by the publisher.
* **[Dead lettering](https://www.rabbitmq.com/docs/dlx) with [TTL](https://www.rabbitmq.com/docs/ttl)**,
  one queue per delay, for a small set of fixed delays.
* **An external scheduler** with its own data store, for long or many delays.

## Supported Versions

| This fork | RabbitMQ | Erlang/OTP |
|-----------|----------|------------|
| 4.3.x     | 4.3.x    | 27, 28     |

Release builds are compiled on OTP 27. Modules compiled on OTP 27 load on OTP 27 and 28, but not
the other way round: the official `rabbitmq:4.3` Docker image runs OTP 27, CloudAMQP runs OTP 28.

## Build and Test

Requires Docker.

```bash
scripts/build.sh             # builds against RabbitMQ v4.3.6 into dist/
scripts/build.sh v4.3.5      # another 4.3.x tag
scripts/smoke-test.sh        # runs the built plugin on real nodes
```

`scripts/smoke-test.sh` checks that:

1. a message published with `x-delay` is delivered after the delay, not before,
2. a delayed message survives a node restart,
3. a message delayed by RabbitMQ 4.2.x with the upstream 4.2.0 plugin is delivered after the node
   is upgraded to 4.3.x with this build.

## Installation

Download the `.ez` file from the [releases](https://github.com/dominikzabcik/rabbitmq-delayed-message-exchange/releases)
of this fork, copy it into the node's [plugins directory](https://www.rabbitmq.com/docs/plugins#plugin-directories)
(`rabbitmq-plugins directories -s`), and enable it:

```bash
rabbitmq-plugins enable rabbitmq_delayed_message_exchange
```

Upgrading from the upstream 4.2.0 plugin: enable all stable feature flags on 4.2, stop the node,
replace the plugin file, start 4.3. Delayed messages are kept.

## The Basics

With this plugin enabled, a user can declare an exchange with the type `x-delayed-message` and
then publish messages with the custom header `x-delay` expressing in
milliseconds a delay time for the message. The message will be
delivered to the respective queues after `x-delay` milliseconds.

## Intended Use Cases

This plugin was designed for delaying message publishing for a number of seconds, minutes, or hours.
A day or two at most.

It is **not a longer term scheduling solution**. If you need to delay publishing by days, weeks, months, or years,
consider using a data store suitable for long-term storage, and an external scheduling tool
of some kind.


## Consider the  Limitations

This plugin adds delayed-messaging (or scheduled-messaging) to
RabbitMQ. Its current design **has multiple significant limitation** (documented below),
consider using an external scheduler and a data store that fits your needs
first.

This plugin badly needs a [new design](https://github.com/rabbitmq/rabbitmq-delayed-message-exchange/issues/229)
and a reimplementation from the ground up.

If you accept the limitations, please read on.

## Usage ##

To use the delayed-messaging feature, declare an exchange with the
type `x-delayed-message`:


```java
// ... elided code ...
Map<String, Object> args = new HashMap<String, Object>();
args.put("x-delayed-type", "direct");
channel.exchangeDeclare("my-exchange", "x-delayed-message", true, false, args);
// ... more code ...
```

Note that we pass an extra header called `x-delayed-type`, more on it
under the _Routing_ section.

Once we have the exchange declared we can publish messages providing a
header telling the plugin for how long to delay our messages:

```java
// ... elided code ...
byte[] messageBodyBytes = "delayed payload".getBytes("UTF-8");
Map<String, Object> headers = new HashMap<String, Object>();
headers.put("x-delay", 5000);
AMQP.BasicProperties.Builder props = new AMQP.BasicProperties.Builder().headers(headers);
channel.basicPublish("my-exchange", "", props.build(), messageBodyBytes);

byte[] messageBodyBytes2 = "more delayed payload".getBytes("UTF-8");
Map<String, Object> headers2 = new HashMap<String, Object>();
headers2.put("x-delay", 1000);
AMQP.BasicProperties.Builder props2 = new AMQP.BasicProperties.Builder().headers(headers2);
channel.basicPublish("my-exchange", "", props2.build(), messageBodyBytes2);
// ... more code ...
```

In the above example we publish two messages, specifying the delay
time with the `x-delay` header. For this example, the plugin will
deliver to our queues first the message with the body `"more delayed
payload"` and then the one with the body `"delayed payload"`.

If the `x-delay` header is not present, then the plugin will proceed
to route the message without delay.

## Routing ##

This plugin allows for flexible routing via the `x-delayed-type`
arguments that can be passed during `exchange.declare`. In the example
above we used `"direct"` as exchange type. That means the plugin
will have the same routing behavior shown by the direct exchange.

If you want a different routing behavior, then you could provide a
different exchange type, like `"topic"` for example. You can also
specify exchange types provided by plugins. Note that this argument is
**required** and **must** refer to an **existing exchange type**.

## Performance Impact ##

Due to the `"x-delayed-type"` argument, one could use this exchange in
place of other exchanges, since the `"x-delayed-message"` exchange
will just act as proxy. Note that there might be some performance
implications if you do this.

For each message that crosses an `"x-delayed-message"` exchange, the
plugin will try to determine if the message has to be expired by
making sure the delay is within range, ie: `Delay > 0, Delay =<
?ERL_MAX_T` (In Erlang a timer can be set up to (2^32)-1 milliseconds
in the future).

If the previous condition holds, then the message will be persisted to
Mnesia and some other logic will kick in to determine if this
particular message delay needs to replace the current scheduled timer
and so on.

This means that while one _could_ use this exchange in place of a
_direct_ or _fanout_ exchange (or any other exchange for that matter),
_it will be slower_ than using the actual exchange. If you don't need
to delay messages, then use the actual exchange.


## Limitations

Delayed messages are stored in a Mnesia table (also see Limitations below)
with a single disk replica on the current node. They will survive a node
restart. While timer(s) that triggered scheduled delivery are not persisted,
it will be re-initialised during plugin activation on node start.
Obviously, only having one copy of a scheduled message in a cluster means
that losing that node or disabling the plugin on it will lose the
messages residing on that node.

The plugin only performs one attempt at publishing each message but since publishing
is local, in practice the only issue that may prevent delivery is the lack of queues
(or bindings) to route to. 

Closely related to the above, the mandatory flag is not supported by this exchange:
we cannot be sure that at the future publishing point in time

 * there is at least one queue we can route to
 * the original connection is still around to send a `basic.return` to
 
Current design of this plugin doesn't really fit scenarios
with a high number of delayed messages (e.g. 100s of thousands or millions).
See [#72](https://github.com/rabbitmq/rabbitmq-delayed-message-exchange/issues/72) for details.

## Disabling the Plugin ##

You can disable this plugin by calling `rabbitmq-plugins disable
rabbitmq_delayed_message_exchange` but note that **ALL DELAYED MESSAGES THAT
HAVEN'T BEEN DELIVERED WILL BE LOST**.

## LICENSE

See the LICENSE file.

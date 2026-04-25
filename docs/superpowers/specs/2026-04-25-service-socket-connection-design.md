# Service Socket Connection Design

Date: 2026-04-25
Branch: `service_socket_connection` (off `streaming_deadlock`)
Parent base commit at branch creation: `989aa38` ("Client::AtomicPipe:
bypass _OUTBOX, use Atomic::Pipe's OUT_BUFFER")
Status: Draft for review

## Parent-branch volatility

`streaming_deadlock` is in flux while this work is in progress. The list of
parent commits at branch-creation time is recorded here so a future rebase
can detect changes that affect this design (especially anything touching
`Role::Outbox`, non-blocking send paths, the service loop, or the
`Client`/`Base::FS`/`Base::DBI` interface).

`streaming_deadlock` tip when this branch was forked:

```
989aa38 Client::AtomicPipe: bypass _OUTBOX, use Atomic::Pipe's OUT_BUFFER
ae3f29b Service: drain outbox before exit
807dfd8 Revert "Service: do not auto-flip set_send_blocking on run"
889b81b Reapply "Service: drain outbox each iteration; select on writable too"
1d1d432 Reapply "Reapply "Client::UnixSocket: non-blocking sends via Role::Outbox""
f9d7ec9 Reapply "Reapply "Client::AtomicPipe: non-blocking sends via Role::Outbox""
77620fb Revert "Reapply "Client::AtomicPipe: non-blocking sends via Role::Outbox""
001dc40 Revert "Reapply "Client::UnixSocket: non-blocking sends via Role::Outbox""
e2e3ed4 Reapply "Client::UnixSocket: non-blocking sends via Role::Outbox"
a7a922f Reapply "Client::AtomicPipe: non-blocking sends via Role::Outbox"
760d993 Revert "Client::AtomicPipe: non-blocking sends via Role::Outbox"
20e9ce2 Revert "Client::UnixSocket: non-blocking sends via Role::Outbox"
e5a85dd Revert "Service: drain outbox each iteration; select on writable too"
89830a4 Service: do not auto-flip set_send_blocking on run
47dea48 Service: flip client to non-blocking AFTER _run_on_start
```

Before each rebase: diff `streaming_deadlock` against `989aa38` and verify
that the assumptions in this design (Outbox shape, service-loop selectability,
client base interface) still hold. Update this spec if any assumption is
invalidated.

## Goal

Add connection-oriented socket transports for IPC services. Services hold a
listening socket (Unix or TCP) and accept persistent, bidirectional streams from
peers. The transport runs alongside an existing message-oriented driver
(MessageFiles, AtomicPipe, MariaDB, etc.) which continues to handle non-service
peers, peer discovery, and stats. The pairing is transparent to user code:
`send_message` automatically uses the right transport per peer.

Two new client classes:

- `IPC::Manager::Client::ServiceUnix` - connection-oriented UNIX-domain stream.
- `IPC::Manager::Client::ServiceIP` - connection-oriented TCP stream, defaulting
  to `127.0.0.1` with an OS-assigned ephemeral port.

A new composite client class wraps the chosen "main" driver together with the
service transport so callers continue to interact with a single
`IPC::Manager::Client` object.

## Non-Goals

- Replacing the existing connectionless `UnixSocket` (SOCK_DGRAM) driver. It
  stays as is for users who want it.
- Cross-host networking. `ServiceIP` is intended for localhost; binding to
  non-loopback addresses is opt-in per service.
- Suspend/reconnect of an established stream connection. Like `UnixSocket`, the
  service-socket layer does not support `suspend`. The main driver continues
  to support suspend if it does today.
- Encryption / TLS. Authentication is via a process-tree-shared UUID key
  (see "Security model"); transport itself is plain stream.

## High-level architecture

```
                Process P1 (main driver: MessageFiles, service transport: ServiceUnix)
                +-----------------------------------------------------------+
                |   IPC::Manager::Client::Composite                         |
                |     +--- main client (MessageFiles)                       |
                |     |     - peer dir, .pid, .name, .stats, .resume        |
                |     |     - .service sidecar (NEW): endpoint info         |
                |     +--- service layer (ServiceUnix)                      |
                |           - listen socket (only when running a service)   |
                |           - stream pool keyed by peer id (concurrent N):  |
                |               svcA -> StreamState                         |
                |               svcB -> StreamState                         |
                |               svcC -> StreamState   (... etc)             |
                +-----------------------------------------------------------+
                       |                       |          |        |
                       | non-service via main  |          |        |
                       v                       v          v        v
                +-------------+         +------+   +------+  +------+
                | regular bus |         | svcA |   | svcB |  | svcC |
                +-------------+         | strm |   | strm |  | strm |
                                        +------+   +------+  +------+
              (one main bus, plus N independent bidirectional streams)
```

A composite client owns:

- `main` - an instance of any existing `IPC::Manager::Client` subclass.
- `service` - an instance of a `Service*` transport (only opens its listen
  socket when the local peer is running a service). The service transport
  is a multiplexer: it manages a pool of concurrently open streams keyed by
  peer id (see "Multi-peer streams" below). One client process can be
  connected to N services simultaneously; one service process can have
  accepted streams from M clients simultaneously.
- A unified `IPC::Manager::Client` interface so neither service code nor user
  code needs to know about the dual layer.

### Multi-peer streams (explicit)

A single composite client maintains independent, concurrent streams to as
many service peers as it has business with. Concretely:

- `streams` is a hash `{peer_id => StreamState}` on the `service` transport.
  Entries are created lazily on first send to that peer (dial side) or on
  successful HELLO acceptance (accept side).
- `send_message($peerA => $msg)` and `send_message($peerB => $msg)` operate
  on different stream entries; they do not serialize through one another and
  do not block one another.
- `get_messages` drains every stream that is ready in the current select
  cycle, in addition to the main driver's messages. There is no per-cycle
  cap; the service loop sees a single combined batch.
- `handles_for_select` returns the union of: main-driver handles + listen
  socket (if any) + every currently open stream socket (read side, plus
  write side for any stream whose Outbox has pending bytes). The set grows
  and shrinks across loop iterations as streams open and close.
- A non-service client (no listener) still uses the multi-stream pool for
  dialed connections to multiple services.
- Stream lifetimes are independent: closing one stream (peer EOF, write
  error, retract) does not affect the others.

This is the normal expected operating shape, not an edge case. A worker
that calls three services to fan out a request is using three streams; a
service that talks to two downstream services and serves four upstream
clients is multiplexing six streams plus its main-driver handles.

## User-facing API

### Spawning

```perl
my $ipcm = ipcm_spawn(
    protocol         => 'MessageFiles',  # main driver
    service_protocol => 'ServiceUnix',   # NEW: service transport
    serializer       => 'JSON',
);
```

`service_protocol` is optional. When absent, behavior is identical to today.

### `ipcm_info` encoding

The current 3-element tuple `[$protocol, $serializer, $route]` gains an
optional 4th element:

```
[$protocol, $serializer, $route, $service_protocol]
```

`$service_protocol` is the bare class name (e.g. `'ServiceUnix'`), normalized
the same way `$protocol` already is. When the 4th element is absent, no
service layer is composed.

The auth key (see "Security model") is NOT in `ipcm_info`. It is propagated
out of band.

### `ipcm_service` parameters

```perl
ipcm_service(
    name          => 'svcA',
    handle_request => sub { ... },

    # ServiceIP only - all optional, default 127.0.0.1 + ephemeral port:
    service_bind  => '127.0.0.1',
    service_port  => 0,                   # 0 means OS-assigned
    service_inet6 => 0,                   # opt-in IPv6
);
```

### `connect`

`ipcm_connect($id, $info)` returns a `Composite` client when `$info` carries a
4th element. Otherwise it returns the main-driver client directly, exactly as
today (no behavior change for existing callers).

A new optional `auth_key` parameter on `ipcm_connect` (and on the composite's
constructor) supplies the auth key needed to open service-socket streams:

```perl
my $con = ipcm_connect($id, $info, auth_key => $spawn->auth_key);
```

`$spawn->auth_key` is a new accessor that returns the in-memory UUID. A
process that connects without an `auth_key` still gets a working composite
for non-service traffic; attempting to send to a service peer raises an
exception explaining the missing key. This matches the requirement that
non-service connections do not need the key but cannot reach services unless
the key is intentionally shared.

In-tree forked services inherit the auth key automatically (the `Spawn`
object closes over it). Exec'd services receive it via
`IPCM_AUTH_KEY_<route_hash>` env var, set by the parent immediately before
`exec` and read by `IPC::Manager::Service::State` on import.

### `send_message`, `get_messages`, etc.

Unchanged signatures. The `Composite` client routes per peer:

- `send_message($peer, ...)`: if `peer_service_endpoint($peer)` resolves, send
  over the (lazily opened) stream. Else delegate to `main->send_message`.
- `get_messages`: collect from `main` and from each ready stream.
- Stats: aggregated and persisted via `main->write_stats`.

## Components

### `IPC::Manager::Client::Composite`

Sits in the inheritance hierarchy between user code and the underlying
clients. Owns:

- `main` - any existing `IPC::Manager::Client` subclass instance.
- `service` - a `Service*` transport instance (always present when the
  composite was constructed with a service_protocol; the listen socket inside
  it is only opened when `start_service_listener` is called).

Responsibilities:

- Forward discovery / peer / stats / suspend / disconnect to `main`.
- Forward message I/O for non-service peers to `main`.
- Forward stream I/O for service peers to `service`.
- Combine `handles_for_select` from both for use by the service loop.
- Enforce auth key on inbound stream connections.

The composite is the only client object that user code sees in dual-driver
mode.

### `IPC::Manager::Client::ServiceUnix`

Provides the connection-oriented Unix socket transport. Not a standalone
client; it is always wrapped by a `Composite`. Responsibilities:

- `start_listener($id, $route)`: post-fork, create
  `<route>/<on_disk_name>.sock` (SOCK_STREAM, non-blocking, listen backlog
  (default 64)), then call `main->publish_service_endpoint(...)` to write the
  `.service` sidecar.
- `accept_pending`: drain the listen socket.
- `dial($peer_endpoint)`: open a non-blocking SOCK_STREAM client connection.
- Per-stream state: read buffer, write buffer (Outbox), framing decoder.
- Frame format and handshake (see "Wire protocol").
- Stops the listener and closes streams on disconnect.

### `IPC::Manager::Client::ServiceIP`

Same shape as `ServiceUnix` but uses TCP. Differences:

- `start_listener`: bind to `service_bind` (default `127.0.0.1`), port
  `service_port` (default `0` = ephemeral). Reads back the bound port via
  `getsockname` and writes
  `{type => 'tcp', host => $bind, port => $port}` to the sidecar.
- `dial`: opens a TCP socket to host/port from the sidecar.
- IPv6 only when `service_inet6 => 1` is set on the service.

### Discovery: `peer_service_endpoint`

New base-client method `peer_service_endpoint($peer_id)` returning
`{type => 'unix', path => '...'}`, `{type => 'tcp', host => ..., port => ...}`,
or `undef`.

- FS-based drivers: read `<route>/<on_disk_name>.service` (JSON serialized).
  Written via `_write_service_endpoint`, read via `_read_service_endpoint`.
- DBI-based drivers: an extra nullable column `service_endpoint` on the
  existing peer table, written when a service starts, read on lookup.
- A peer that is not a service (or whose service has not yet published its
  endpoint) returns `undef`.

The `.service` sidecar is removed by the service on clean shutdown
(`pre_disconnect_hook` extension). On crash, the next `peers()` consumer must
treat a stale `.service` as "best-effort": if `dial()` fails with ECONNREFUSED
the composite must fall back through the same logic as a peer that has gone
away (existing behavior under main driver).

### Service-loop integration

`IPC::Manager::Role::Service::select_handles` already calls
`have_handles_for_select` and `handles_for_select` on the client. The
composite reports the union of:

- `main->handles_for_select` (if any),
- listen socket (if a service is running here),
- every per-peer stream socket currently established (read side, plus
  write side for any stream whose Outbox has pending bytes),
- every in-progress (post-accept, pre-HELLO-complete) inbound socket.

#### Per-iteration responsibilities of `watch()`

The existing `IPC::Manager::Role::Service::watch` loop must drive the
service-socket layer too. Currently `watch` does (in order):

1. `reap_children`
2. `select->can_read($cycle)`
3. `client->get_messages` if any handle was readable
4. `peer_delta`
5. interval check
6. `pid_watch`

In dual-driver mode, step 3 is replaced by an expanded sequence on the
composite. After `can_read($cycle)` returns truthy:

a. **Listener accept.** If the listen socket is in the readable set,
   `service->accept_pending` is called. It loops `accept` non-blocking
   until EAGAIN, registering each new fd as an "in-progress" connection
   awaiting HELLO. Newly accepted fds are added to the next select set
   so their HELLO frame can be read.

b. **Handshake advance.** For every readable in-progress fd,
   `service->advance_handshakes` reads as much as possible. When a HELLO
   frame is fully decoded:
   - validate `auth_key`; mismatch or missing => close fd silently and
     record an entry in the per-cycle "rejected connections" accumulator
     (reason `bad_key` or `missing_key`)
   - if the HELLO is structurally invalid / not decodable => close fd
     and record a `malformed_hello` rejection
   - check for an existing live stream to that peer id; if one exists,
     apply the lower-`connection_uuid` rule and close the loser
   - on accept, send HELLO_ACK, promote the fd to the per-peer stream
     pool, record the peer id in the per-cycle "new connections"
     accumulator
   HELLO that does not arrive within the handshake timeout (default 2s
   tracked by handshake-start time, checked each iteration) closes the
   fd and records a `handshake_timeout` rejection.

c. **Stream reads.** For every readable established stream,
   `service->drain_stream` reads bytes into the per-stream buffer and
   pulls every complete frame out as a deserialized
   `IPC::Manager::Message`. Stream EOF or framing error closes the
   stream and records its peer id in the per-cycle "lost connections"
   accumulator.

d. **Stream writes.** For every writable established stream whose
   Outbox is non-empty, drain as many bytes as the kernel takes.

e. **Main driver reads.** The composite's `get_messages` calls
   `main->get_messages` and concatenates the result with the messages
   collected in step c. The combined list is what `watch` puts in
   `activity{messages}`.

f. **Drain accumulators.** `service->take_new_connections`,
   `service->take_lost_connections`, and
   `service->take_rejected_connections` return the per-cycle accumulators
   from steps a/b/c. `watch` puts them in `activity{new_connections}`,
   `activity{lost_connections}`, and `activity{rejected_connections}`
   (each only when non-empty).

#### New activity-hash keys

```
{
    ...existing keys...

    # Arrayref of peer ids whose inbound stream completed HELLO this
    # cycle. Set only when non-empty.
    new_connections => ['svcClientA', 'svcClientB'],

    # Arrayref of peer ids whose established stream was closed (EOF,
    # framing error, or duplicate-race loss) this cycle. Set only when
    # non-empty. Distinct from peer_delta: peer_delta reflects main-
    # driver peer presence; lost_connections reflects only the stream
    # layer. (Note: failures during the HELLO handshake are reported
    # under rejected_connections, not lost_connections - until a
    # connection is established it is never "lost".)
    lost_connections => ['svcClientC'],

    # Arrayref of hashrefs describing inbound connection attempts that
    # were rejected before promotion to an established stream. Set only
    # when non-empty. Each entry:
    #   {
    #       reason       => 'bad_key' | 'missing_key' |
    #                       'malformed_hello' | 'handshake_timeout',
    #       claimed_from => $peer_id_string_or_undef,
    #       remote       => { type => 'tcp',  host => '...', port => N }
    #                    || { type => 'unix', path => '...' }
    #                    || undef,
    #       at           => $hires_time,
    #   }
    # `claimed_from` is the value of the `from` field in the HELLO frame
    # if one was decoded before the rejection, otherwise undef. It must
    # NOT be trusted (the connection failed auth); it is recorded only
    # so callers can correlate logs.
    rejected_connections => [
        { reason => 'bad_key', claimed_from => 'svcClientD',
          remote => { type => 'unix', path => '...' }, at => 1714065023.42 },
    ],
}
```

#### New role hooks

Three optional callbacks are added to `IPC::Manager::Role::Service`,
parallel to `on_peer_delta`:

- `on_new_connection` - called once per peer id in
  `activity{new_connections}`.
- `on_lost_connection` - called once per peer id in
  `activity{lost_connections}`.
- `on_rejected_connection` - called once per entry in
  `activity{rejected_connections}` with the rejection hashref described
  above.

Default implementations are no-ops. The default `on_rejected_connection`
SHOULD log via `$self->debug` at minimum so that a misconfigured peer
without an explicit handler still surfaces something visible; this is
explicit in the role and called out so reviewers can object.
`IPC::Manager::Service` exposes matching constructor params and
`push_*` / `clear_*` accessors using the same code-generation pattern as
the existing `@ACTIONS` list.

`Role::Service::run` consumes the new keys after `pid_watch` and before
`messages`, dispatching the callbacks via `_run_on_new_connection`,
`_run_on_lost_connection`, and `_run_on_rejected_connection` (matching
the existing `_run_on_*` wrapper pattern that goes through `try`).

#### Files affected by this section

- `IPC::Manager::Role::Service::watch`: replace the single
  `client->get_messages` call with the expanded sequence above; populate
  the two new activity keys.
- `IPC::Manager::Role::Service::run`: dispatch the two new keys.
- `IPC::Manager::Role::Service`: add `on_new_connection` and
  `on_lost_connection` to the role's `requires`/default-no-op set.
- `IPC::Manager::Service`: extend `@ACTIONS` with
  `on_new_connection` and `on_lost_connection`.
- `IPC::Manager::Client::Composite`: provide
  `accept_pending`, `advance_handshakes`, `drain_stream`,
  `take_new_connections`, `take_lost_connections`,
  `take_rejected_connections`. The first three may be implemented on
  `Base::ServiceSocket` and exposed through the composite.

### Service startup flow

1. `ipcm_service(...)` is called from user code.
2. `pre_fork_hook` runs in the parent (existing).
3. `fork()`.
4. In the child: `post_fork_hook` runs (existing).
5. After `post_fork_hook`, the composite's `start_service_listener` is
   invoked. This:
   - asks the `service` transport to open its listen socket,
   - publishes the endpoint via the main driver (so peers can discover it),
   - signals the parent's handle that the service is ready (existing
     mechanism via `IPC::Manager::Service::Handle->ready`).
6. Service loop runs as today.

The endpoint is therefore decided post-fork and reported to the parent and
peers strictly through the discovery layer. The parent never needs the
endpoint for its own bookkeeping.

## Wire protocol

### Framing

Every frame on a service-socket stream is length-prefixed:

```
+------------+-----------------+
| 4 bytes    | N bytes         |
| big-endian | serialized body |
| length N   |                 |
+------------+-----------------+
```

Body is the serializer's output (default JSON). 32-bit length is sufficient
(>4 GiB per frame, well past any realistic message). The reader buffers
partial reads until a full frame is assembled; a partial frame at EOF is
treated as a connection error and the stream is closed.

### Handshake

After TCP/Unix `connect()` completes, the dialer sends one HELLO frame:

```json
{
  "ipcm_hello":     1,
  "from":           "<dialer_peer_id>",
  "auth_key":       "<uuid>",
  "connection_uuid":"<uuid>"
}
```

The server validates `auth_key`. On mismatch the server closes the connection
without sending a response. On success the server replies with one HELLO_ACK
frame:

```json
{
  "ipcm_hello_ack":  1,
  "from":            "<server_peer_id>",
  "connection_uuid": "<uuid>"
}
```

After exchange, the stream carries `IPC::Manager::Message` payloads in both
directions, framed as above.

### Duplicate-connection race

If both ends of a service-to-service pair dial each other simultaneously, both
HELLOs may complete. Each side then sees two live streams to the same peer.
Resolution rule (applied symmetrically by both sides):

- Compare the `connection_uuid` strings of the two streams to the same peer.
- Keep the lower one (lexicographic).
- Drop the higher one (close locally; remote also drops).

This is deterministic and clock-free. The window is small (lazy dial, dial
only on first send).

## Security model

### Auth key

- Generated as a UUID at `ipcm_spawn` time.
- Stored on the in-memory `IPC::Manager::Spawn` object.
- Not included in `$spawn->info` (the public ipcm_info string).
- Not persisted to FS sidecars or DBI columns.
- Inherited by forked child processes via Perl variable closure.
- For `exec`-based service launch (`exec` param to `ipcm_service`): exported
  in the child's environment as `IPCM_AUTH_KEY_<route_hash>=<uuid>` (route
  hash = `substr(sha256_hex($route), 0, 16)`) so multiple ipcm instances can
  coexist in one process tree. The exec'd service module reads it on import.
- The composite transport reads it from a process-local registry keyed by
  route, populated either at spawn time (parent) or at exec import time
  (child).

### Connection acceptance

- Server requires the HELLO frame within a short timeout (default 2s, kill on
  timeout).
- If `auth_key` is missing or wrong, the server closes the connection with
  no reply.
- Successful HELLO is logged at debug level only; no auth events on stderr by
  default.

### Out-of-process callers

- A process started without inheriting / being told the auth key cannot
  connect to any service via the service-socket transport. It can still use
  the main driver for messages to non-service peers - the existing
  permissions model is unchanged.

## Lifecycle

### Connection lifecycle

- Streams are opened lazily on the first send to that peer.
- Streams are reused for all subsequent messages in either direction.
- A composite holds an unbounded pool of concurrent streams (one per
  service peer). Opening a stream to peer B does not close or stall the
  stream to peer A.
- Each stream has its own read buffer, its own Outbox, and its own framing
  decoder. Read/write activity on different streams is independent.
- On EOF / write error, the affected stream is removed from the pool;
  other streams are untouched. The next `send_message` to that peer
  triggers a redial.
- The main driver remains the source of truth for "is this peer alive?"
  (existing peer_delta mechanism). A stream EOF alone does not declare a
  peer gone; it only invalidates that pool entry.

### Shutdown

- `disconnect`: cleanly close all streams (drain Outbox first, then close),
  unlink the listen socket (Unix), and have the main driver retract the
  `.service` sidecar (FS) or null out the `service_endpoint` column (DBI)
  via a new `retract_service_endpoint` method paired with
  `publish_service_endpoint`. Then call `main->disconnect`.
- `Spawn->shutdown`: existing terminate broadcast goes over whichever
  transport is appropriate per peer (services receive over their accepted
  socket; non-services receive via main).

## Outbox / non-blocking writes

The streaming_deadlock branch's `Role::Outbox` non-blocking send work applies
directly:

- Stream `send_message` enqueues a frame; the writable handle is registered
  with the service loop's `IO::Select` write set.
- On writable readiness, the Outbox drains.
- On `disconnect`, the Outbox is drained synchronously before closing.

## Error handling

| Error                            | Action                                                     |
| -------------------------------- | ---------------------------------------------------------- |
| auth key mismatch on accept      | close connection, no reply                                 |
| HELLO timeout                    | close connection                                           |
| dial ECONNREFUSED                | drop cached endpoint, raise from `send_message`            |
| EOF mid-frame                    | close stream, remove from cache; retry on next send        |
| length-prefix > sane upper bound | close stream, raise (defensive against corrupt peer)       |
| listen-socket bind failure       | service startup fails; existing readiness-timeout handling |
| sidecar publish failure          | service startup fails (peer cannot be discovered)          |

`viable()` for `ServiceUnix` checks `IO::Socket::UNIX` >= 1.55 (matches
existing `UnixSocket` driver). `viable()` for `ServiceIP` checks
`IO::Socket::INET`.

## Testing

Tests live alongside existing protocol tests:

- `t/integration/ServiceUnix.t` and `t/integration/ServiceIP.t`: per-subtest
  files mirroring the existing per-protocol test split.
- New harness coverage in `IPC::Manager::Test` so integration scenarios run
  against composite mode (e.g. `MessageFiles + ServiceUnix`,
  `AtomicPipe + ServiceUnix`, `SQLite + ServiceIP`).
- Specific scenarios:
  - service receives request from non-service client over stream, replies on
    same stream
  - one client connected to multiple services concurrently: send to svcA,
    svcB, svcC in interleaved order, verify per-peer ordering and that no
    stream blocks another
  - `on_new_connection` callback fires with the correct peer id when a
    client connects to a service, before any messages from that peer are
    delivered
  - `on_lost_connection` callback fires when an established stream
    closes (peer EOF, framing error, duplicate-race loss) and is
    independent of `on_peer_delta`
  - `on_rejected_connection` callback fires with the correct
    `reason` (`bad_key`, `missing_key`, `malformed_hello`,
    `handshake_timeout`) and remote info; verifies that auth-failed
    attempts do NOT appear in `on_lost_connection` or `on_new_connection`
  - `activity{new_connections}`, `activity{lost_connections}`, and
    `activity{rejected_connections}` keys appear in `on_all` only on
    cycles where they are non-empty
  - rejected attempts do not leak peer ids into the established peer
    set (no false entries in `peers()`, `peer_delta`, or stats)
  - one service accepting from multiple clients concurrently: each client
    sends a request, all get correct responses on their own streams
  - service-to-service messaging
  - simultaneous-dial duplicate-connection race resolution (force the race
    via a synchronization point and verify the lower-uuid stream survives)
  - auth-key reject (wrong key from a manually crafted client)
  - exec'd service inherits auth key via env var
  - composite mode falls back to main driver for non-service peers
  - service crash mid-stream: peers redial successfully after the service
    restarts (or the main driver's peer_delta fires the disappearance)
  - sanity_check (`Spawn->sanity_delta`) accounts for stream-delivered
    messages identically to main-driver-delivered ones

## Affected files

New:

- `lib/IPC/Manager/Client/ServiceUnix.pm`
- `lib/IPC/Manager/Client/ServiceIP.pm`
- `lib/IPC/Manager/Client/Composite.pm`
- `lib/IPC/Manager/Base/ServiceSocket.pm` (shared logic between ServiceUnix
  and ServiceIP: framing, handshake, stream cache, Outbox integration)
- `t/integration/ServiceUnix.t`, `t/integration/ServiceIP.t`, plus subtest
  splits per existing pattern.

Modified:

- `lib/IPC/Manager.pm`: parse `service_protocol`, build 4-element ipcm_info,
  wire composite construction in `_connect` and `ipcm_spawn`.
- `lib/IPC/Manager/Spawn.pm`: generate and hold the auth key; expose it via
  a new `auth_key` accessor; do NOT include it in `info()`; export it to the
  env (`IPCM_AUTH_KEY_<route_hash>`) for `exec`-based services and clear the
  env var after exec returns.
- `lib/IPC/Manager/Service/State.pm`: read the auth key on exec import; pass
  through to the composite client.
- `lib/IPC/Manager/Client.pm`: add `peer_service_endpoint` (default returning
  undef).
- `lib/IPC/Manager/Base/FS.pm`: implement
  `peer_service_endpoint` (read `.service`), `publish_service_endpoint`
  (write `.service`), and clean it up in `post_disconnect_hook`.
- `lib/IPC/Manager/Base/DBI.pm`: same, against the peer table column.
- `lib/IPC/Manager/Role/Service.pm`: expand `watch()` (accept_pending,
  advance_handshakes, drain_stream, write-side drain,
  take_*_connections), add new activity keys `new_connections`,
  `lost_connections`, and `rejected_connections`, dispatch them in
  `run()` via `_run_on_new_connection`, `_run_on_lost_connection`, and
  `_run_on_rejected_connection`, add no-op defaults plus a debug-log
  default for `run_on_rejected_connection`.
- `lib/IPC/Manager/Service.pm`: add `on_new_connection`,
  `on_lost_connection`, and `on_rejected_connection` to `@ACTIONS` so
  the existing accessor codegen produces `push_*` / `clear_*` / `run_*`
  for them.

Companion update (per CLAUDE.md): mirror any base-class changes into
`../IPC-Manager-Client-SharedMem/` if the `Client` interface changes
materially. The composite layer should not require changes there because
SharedMem is itself a "main" driver, not a service transport, and a future
user could pair it with a `Service*` transport just like any other main
driver. The public-method additions (`peer_service_endpoint`,
`publish_service_endpoint`) need stub no-op implementations or inheritance to
keep that distribution viable.

## Open questions resolved during design

| #  | Question                                | Resolution                                                                                                               |
| -- | --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| Q1 | Pure-`Service*` mode without main?      | No. Service transports are always paired with a main driver (a).                                                         |
| Q2 | Connection topology                     | One bidirectional stream per pair (a). Service-to-service: lazy first-need dial; duplicate streams resolved by uuid tiebreak. |
| Q3 | Framing                                 | 4-byte big-endian length prefix + serialized body. HELLO/HELLO_ACK handshake including auth key and connection_uuid.     |
| Q4 | Discovery storage                       | `.service` sidecar (FS), `service_endpoint` column (DBI). Generic `peer_service_endpoint` accessor on base client.       |
| Q5 | Spawn API + ipcm_info encoding          | `service_protocol` keyword to spawn (i). Optional 4th element on the ipcm_info tuple. ServiceIP defaults: `127.0.0.1`, ephemeral port. |

## Implementation phasing

A single implementation plan is reasonable; suggested phasing inside the plan:

1. Composite client skeleton + dispatch logic, pass-through to main, no
   service layer yet (verify nothing breaks for any existing protocol).
2. `Base::ServiceSocket` (framing, handshake, stream cache, auth-key
   plumbing) with a unit-test harness that uses local socketpair pairs.
3. `ServiceUnix` on top of `Base::ServiceSocket`. Sidecar publish/consume.
   Integration tests with `MessageFiles + ServiceUnix`.
4. `ServiceIP`. Integration tests with `MessageFiles + ServiceIP` and at
   least one DBI driver (SQLite is fastest in CI).
5. Service-to-service tests including duplicate-connection race.
6. Auth-key path, exec inheritance via env var.
7. Sanity-check parity, doc updates, POD, and SharedMem companion update.

## Risks and mitigations

- **Hidden coupling between main driver and service layer**: kept loose by
  funneling all main-driver interaction through `peer_service_endpoint` /
  `publish_service_endpoint` and standard `IPC::Manager::Client` methods.
  No driver-specific code in the composite.
- **Stale `.service` sidecar after crash**: tolerated by lazy redial that
  treats ECONNREFUSED as "peer gone, fall through to main-driver behavior".
  Optional cleanup pass in `Spawn->wait` for sidecars whose pidfile is gone.
- **Auth-key leakage via env var**: scoped per route (`IPCM_AUTH_KEY_<hash>`)
  and only set when `exec`-launching a service. In-process forks inherit by
  Perl closure with no env exposure.
- **Per-peer stream count growth**: bounded by the number of distinct service
  peers a client talks to. No idle-timeout in v1; if it becomes a problem
  later, add a configurable max-idle close.

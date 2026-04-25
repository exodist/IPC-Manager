# Service Socket Connection Design

Date: 2026-04-25
Branch: `service_socket_connection` (off `streaming_deadlock`)
Status: Draft for review

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
                +--------------------------------------------------------+
                |   IPC::Manager::Client::Composite                      |
                |     +--- main client (MessageFiles)                    |
                |     |     - peer dir, .pid, .name, .stats, .resume     |
                |     |     - .service sidecar (NEW): endpoint info      |
                |     +--- service layer (ServiceUnix)                   |
                |           - listen socket (only when running a service)|
                |           - stream cache: peer_id -> StreamState       |
                +--------------------------------------------------------+
                       |                              ^
                       | non-service peers via main   | bidirectional streams
                       v                              v
                +-------------+              +-------------------+
                | regular bus |              |  per-peer streams |
                +-------------+              +-------------------+
```

A composite client owns:

- `main` - an instance of any existing `IPC::Manager::Client` subclass.
- `service` - an instance of a `Service*` transport (only opens its listen
  socket when the local peer is running a service).
- A unified `IPC::Manager::Client` interface so neither service code nor user
  code needs to know about the dual layer.

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
- every per-peer stream socket currently established.

Service code (`Role::Service`, `Service.pm`) is unchanged.

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
- On EOF / write error, the stream is removed from the cache. The next
  `send_message` to that peer triggers a redial (lazy reconnect for
  service-to-service / client-to-service traffic).
- The main driver remains the source of truth for "is this peer alive?"
  (existing peer_delta mechanism). A stream EOF alone does not declare a peer
  gone; it only invalidates the stream cache entry.

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

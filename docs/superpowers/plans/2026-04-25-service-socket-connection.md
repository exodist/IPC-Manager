# Service Socket Connection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `IPC::Manager::Client::ServiceUnix` and `IPC::Manager::Client::ServiceIP` connection-oriented service transports, paired with any main driver via a new `IPC::Manager::Client::Composite` wrapper, with a process-tree-shared UUID auth key, multi-stream concurrency, and full integration with the existing service event loop.

**Architecture:** Composite client owns a main driver (existing) plus a `Service*` transport (new). `Base::ServiceSocket` provides shared framing, handshake, and stream-pool logic. `Role::Service::watch` is expanded to drive accept/handshake/stream-IO each cycle and emits three new activity keys (`new_connections`, `lost_connections`, `rejected_connections`). The full design is in `docs/superpowers/specs/2026-04-25-service-socket-connection-design.md` — read it before starting; this plan presumes you have.

**Tech Stack:** Perl 5, `Object::HashBase`, `Role::Tiny`, `IO::Select`, `IO::Socket::UNIX`, `IO::Socket::INET`, `Test2::V0` (unit), `Test2::V1 -ipP` + `Test2::IPC` (integration), `Test2::Util::UUID::gen_uuid`, `Digest::SHA::sha256_hex`. Existing project conventions per `CLAUDE.md`: `parent` for inheritance, `croak` for user-facing errors, `//=` defaults, no trailing whitespace, no emojis.

**Conventions you MUST follow per `CLAUDE.md`:**
- Run tests with `prove -Ilib -j16 -r t/` (5-minute / 300000ms timeout). For verbose: `prove -Ilib -v t/...`.
- One commit per logical change. Use `git add <specific-files>` (never `git add -A` or `.`). Commit message style: short imperative subject, optional body. Co-author trailer is project-standard but optional.
- Mirror any `IPC::Manager::Client` base-class additions into `../IPC-Manager-Client-SharedMem/` at the end of the plan (Task 31).
- Guard every `eval` block: `eval { ...; 1 } or warn $@` patterns. The only exception is `_viable()`.

---

## File Structure

### New files

| Path                                          | Purpose                                                                                            |
| --------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| `lib/IPC/Manager/Base/ServiceSocket.pm`       | Shared framing, handshake state machine, stream pool, accumulators                                 |
| `lib/IPC/Manager/Client/ServiceUnix.pm`       | UNIX-domain SOCK_STREAM transport (subclass of `Base::ServiceSocket`)                              |
| `lib/IPC/Manager/Client/ServiceIP.pm`         | TCP transport (subclass of `Base::ServiceSocket`)                                                  |
| `lib/IPC/Manager/Client/Composite.pm`         | Wraps main driver + service transport, presents `IPC::Manager::Client` interface                   |
| `t/unit/Base-ServiceSocket.pm`                | Unit tests: framing, handshake decode, accumulators                                                |
| `t/unit/Client-ServiceUnix.t`                 | Unit tests for ServiceUnix specifics                                                               |
| `t/unit/Client-ServiceIP.t`                   | Unit tests for ServiceIP specifics                                                                 |
| `t/unit/Client-Composite.t`                   | Unit tests for Composite dispatch                                                                  |
| `t/ServiceUnix/test_*.t`                      | Integration tests, one per subtest (mirrors `t/UnixSocket/test_*.t`); composite mode               |
| `t/ServiceIP/test_*.t`                        | Same as above for ServiceIP                                                                        |
| `t/unit/composite_auth_key.t`                 | Unit tests for auth-key generation, env var, accessor                                              |
| `t/unit/composite_dup_race.t`                 | Forces simultaneous dial; verifies lower-uuid wins                                                 |
| `t/unit/composite_rejected_connections.t`     | Tests `bad_key` / `missing_key` / `malformed_hello` / `handshake_timeout` rejection categorization |

### Modified files

| Path                                  | Change                                                                                                                                |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `lib/IPC/Manager.pm`                  | Parse `service_protocol`, build composite in `_connect`, accept `auth_key` param                                                      |
| `lib/IPC/Manager/Spawn.pm`            | Generate auth_key (UUID), `auth_key` accessor, 4-tuple `info()`, env-var export for exec                                              |
| `lib/IPC/Manager/Service/State.pm`    | Read auth_key from env on import; pass to composite                                                                                   |
| `lib/IPC/Manager/Client.pm`           | Add `peer_service_endpoint`, `publish_service_endpoint`, `retract_service_endpoint` defaults                                          |
| `lib/IPC/Manager/Base/FS.pm`          | Implement endpoint methods via `<on_disk>.service` sidecar; teach `peers()` to skip `.service`                                        |
| `lib/IPC/Manager/Base/DBI.pm`         | Implement endpoint methods via new `service_endpoint TEXT` column; teach `init_db` migrations                                         |
| `lib/IPC/Manager/Role/Service.pm`     | Expand `watch()`; add `new_connections`/`lost_connections`/`rejected_connections` activity keys; dispatch in `run()`                  |
| `lib/IPC/Manager/Service.pm`          | Extend `@ACTIONS` with `on_new_connection`/`on_lost_connection`/`on_rejected_connection`                                              |
| `lib/IPC/Manager/Service/State.pm`    | After `post_fork_hook`, call composite's `start_service_listener` if applicable                                                       |
| `lib/IPC/Manager/Test.pm`             | New test methods: multi-service connect, multi-client accept, dup-race, rejection categorization                                      |

### Companion (separate repo)

| Path                                              | Change                                                                                |
| ------------------------------------------------- | ------------------------------------------------------------------------------------- |
| `../IPC-Manager-Client-SharedMem/lib/...`         | Inherit defaults from base; no-op `peer_service_endpoint` is sufficient (Task 31)     |

---

## Phase A — Foundations (auth key + endpoint metadata)

### Task 1: Auth key on Spawn

**Files:**
- Modify: `lib/IPC/Manager/Spawn.pm`
- Test: `t/unit/Spawn.t`

- [ ] **Step 1: Write failing test**

Append to `t/unit/Spawn.t`:

```perl
subtest auth_key => sub {
    my $spawn = IPC::Manager::Spawn->new(
        protocol   => 'IPC::Manager::Client::MessageFiles',
        route      => '/tmp',
        serializer => 'IPC::Manager::Serializer::JSON',
        guard      => 0,
    );

    my $key = $spawn->auth_key;
    like($key, qr/^[0-9a-fA-F-]{30,}$/, 'auth_key is a UUID-ish string');
    is($spawn->auth_key, $key, 'auth_key is stable across calls');

    my $info = $spawn->info;
    unlike($info, qr/\Q$key\E/, 'auth_key is not in info()');
};
```

- [ ] **Step 2: Run test, verify it fails**

```
prove -Ilib -v t/unit/Spawn.t
```
Expected: failure (`auth_key` is not a method).

- [ ] **Step 3: Add UUID generation and accessor**

In `lib/IPC/Manager/Spawn.pm`:

Add to imports near top:
```perl
use Test2::Util::UUID qw/gen_uuid/;
```

Add to `Object::HashBase` field list (after `signal`):
```perl
    <auth_key
```

Update `init`:
```perl
sub init {
    my $self = shift;

    $self->{+PID}      //= $$;
    $self->{+GUARD}    //= 1;
    $self->{+AUTH_KEY} //= gen_uuid();

    croak "'protocol' is a required attribute"   unless $self->{+PROTOCOL};
    croak "'route' is a required attribute"      unless $self->{+ROUTE};
    croak "'serializer' is a required attribute" unless $self->{+SERIALIZER};
}
```

`info()` is unchanged in this task — auth_key must NOT appear in it.

- [ ] **Step 4: Run test, verify it passes**

```
prove -Ilib -v t/unit/Spawn.t
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/IPC/Manager/Spawn.pm t/unit/Spawn.t
git commit -m "Spawn: generate UUID auth_key, accessor, not in info()"
```

---

### Task 2: Service-endpoint base hooks on `IPC::Manager::Client`

**Files:**
- Modify: `lib/IPC/Manager/Client.pm`
- Test: `t/unit/Client.t`

- [ ] **Step 1: Write failing test**

Append to `t/unit/Client.t`:

```perl
subtest service_endpoint_defaults => sub {
    my $class = 'IPC::Manager::Client';
    can_ok($class, qw/peer_service_endpoint publish_service_endpoint retract_service_endpoint/);

    my $stub = bless {}, $class;
    is($stub->peer_service_endpoint('any'), undef, 'default returns undef');

    ok(lives { $stub->publish_service_endpoint('any', { type => 'unix', path => '/x' }) },
       'default publish is a no-op');

    ok(lives { $stub->retract_service_endpoint('any') },
       'default retract is a no-op');
};
```

- [ ] **Step 2: Run, verify FAIL**

```
prove -Ilib -v t/unit/Client.t
```

- [ ] **Step 3: Add base methods**

In `lib/IPC/Manager/Client.pm`, near other default methods (around the `peer_left` no-op):

```perl
sub peer_service_endpoint   { undef }
sub publish_service_endpoint { }
sub retract_service_endpoint { }
```

- [ ] **Step 4: Run, verify PASS**

- [ ] **Step 5: Commit**

```bash
git add lib/IPC/Manager/Client.pm t/unit/Client.t
git commit -m "Client: add default service-endpoint hooks (no-ops)"
```

---

### Task 3: `Base::FS` `.service` sidecar implementation

**Files:**
- Modify: `lib/IPC/Manager/Base/FS.pm`
- Test: `t/unit/Base-FS-NoInotify.t` (and `t/unit/Base-FS-Inotify.t`)

- [ ] **Step 1: Write failing test**

Add a subtest to `t/unit/Base-FS-NoInotify.t` (mirror it later in the inotify variant):

```perl
subtest service_endpoint_sidecar => sub {
    my $tmp = File::Temp::tempdir(CLEANUP => 1);

    my $client = IPC::Manager::Client::MessageFiles->new(
        id         => 'svc',
        route      => $tmp,
        serializer => 'IPC::Manager::Serializer::JSON',
    );

    is($client->peer_service_endpoint('svc'), undef, 'no sidecar yet');

    $client->publish_service_endpoint('svc', { type => 'unix', path => '/tmp/x.sock' });
    is_deeply(
        $client->peer_service_endpoint('svc'),
        { type => 'unix', path => '/tmp/x.sock' },
        'sidecar round-trips',
    );

    my @peers_with_self = sort($client->peers, $client->id);
    ok(!grep(/\.service$/, @peers_with_self), 'peers() ignores .service files');

    $client->retract_service_endpoint('svc');
    is($client->peer_service_endpoint('svc'), undef, 'retracted');

    $client->disconnect;
};
```

- [ ] **Step 2: FAIL**

```
prove -Ilib -v t/unit/Base-FS-NoInotify.t
```

- [ ] **Step 3: Implement sidecar methods**

In `lib/IPC/Manager/Base/FS.pm`:

After `peer_pid_file`:

```perl
sub service_endpoint_file {
    my $self = shift;
    my ($peer_id) = @_;
    $peer_id //= $self->{+ID};
    return File::Spec->catfile($self->{+ROUTE}, $self->on_disk_name($peer_id) . ".service");
}

sub peer_service_endpoint {
    my $self = shift;
    my ($peer_id) = @_;
    croak "'peer_id' is required" unless $peer_id;

    my $file = $self->service_endpoint_file($peer_id);
    return undef unless -e $file;

    open(my $fh, '<', $file) or return undef;
    my $body = do { local $/; <$fh> };
    close($fh);

    my $endpoint;
    return undef unless eval { $endpoint = $self->{+SERIALIZER}->deserialize($body); 1 };
    return $endpoint;
}

sub publish_service_endpoint {
    my $self = shift;
    my ($peer_id, $endpoint) = @_;
    croak "'peer_id' is required"  unless $peer_id;
    croak "'endpoint' is required" unless $endpoint && ref($endpoint) eq 'HASH';

    my $file = $self->service_endpoint_file($peer_id);
    my $pend = $file . ".pend";

    open(my $fh, '>', $pend) or die "Could not open '$pend': $!";
    print $fh $self->{+SERIALIZER}->serialize($endpoint);
    close($fh);

    rename($pend, $file) or die "Could not rename '$pend' -> '$file': $!";
}

sub retract_service_endpoint {
    my $self = shift;
    my ($peer_id) = @_;
    $peer_id //= $self->{+ID};

    my $file = $self->service_endpoint_file($peer_id);
    return unless -e $file;
    unlink($file) or warn "Could not unlink '$file': $!";
}
```

Update the `peers()` filter in `lib/IPC/Manager/Base/FS.pm` (line ~307):

```perl
        next if $file =~ m/\.(?:pid|name|resume|stats|service)$/;
```

Update `post_disconnect_hook` to retract its own sidecar before destroying its directory:

```perl
sub post_disconnect_hook {
    my $self = shift;
    $self->SUPER::post_disconnect_hook;
    $self->retract_service_endpoint($self->{+ID});
    my $path = eval { $self->path } // return;
    remove_tree($path, {keep_root => 0, safe => 1}) if -e $path;
}
```

- [ ] **Step 4: PASS**

```
prove -Ilib -v t/unit/Base-FS-NoInotify.t
```

- [ ] **Step 5: Commit**

```bash
git add lib/IPC/Manager/Base/FS.pm t/unit/Base-FS-NoInotify.t
git commit -m "Base::FS: implement .service sidecar endpoint metadata"
```

---

### Task 4: `Base::DBI` `service_endpoint` column

**Files:**
- Modify: `lib/IPC/Manager/Base/DBI.pm`, `lib/IPC/Manager/Client/SQLite.pm`, and any other DBI subclass that defines `table_sql` (`MariaDB`, `MySQL`, `PostgreSQL`).
- Test: `t/unit/Base-DBI.t`, `t/unit/Client-SQLite.t`

- [ ] **Step 1: Write failing test**

Append to `t/unit/Client-SQLite.t`:

```perl
subtest service_endpoint => sub {
    skip_all 'No SQLite' unless eval { require DBD::SQLite; 1 };

    my (undef, $dsn) = ('', 'dbi:SQLite::memory:');
    my $spawn = ipcm_spawn(protocol => 'SQLite', route => $dsn);
    my $c = $spawn->connect('peerA');

    is($c->peer_service_endpoint('peerA'), undef, 'no endpoint yet');
    $c->publish_service_endpoint('peerA', { type => 'tcp', host => '127.0.0.1', port => 1234 });
    is_deeply(
        $c->peer_service_endpoint('peerA'),
        { type => 'tcp', host => '127.0.0.1', port => 1234 },
        'endpoint round-trips through DBI',
    );
    $c->retract_service_endpoint('peerA');
    is($c->peer_service_endpoint('peerA'), undef, 'retracted');
};
```

- [ ] **Step 2: FAIL**

- [ ] **Step 3: Add column + methods**

In `lib/IPC/Manager/Base/DBI.pm`, add methods after `peer_exists`:

```perl
sub peer_service_endpoint {
    my $self = shift;
    my ($peer_id) = @_;
    croak "'peer_id' is required" unless $peer_id;

    my $dbh = $self->dbh;
    my $e   = $self->escape;
    my $sth = $dbh->prepare(
        "SELECT ${e}service_endpoint${e} FROM ipcm_peers WHERE ${e}id${e} = ?"
    ) or die $dbh->errstr;
    $sth->execute($peer_id);
    my $row = $sth->fetchrow_arrayref or return undef;
    my $val = $row->[0];
    return undef unless defined $val && length $val;

    my $out;
    return undef unless eval { $out = $self->{+SERIALIZER}->deserialize($val); 1 };
    return $out;
}

sub publish_service_endpoint {
    my $self = shift;
    my ($peer_id, $endpoint) = @_;
    croak "'peer_id' is required"  unless $peer_id;
    croak "'endpoint' is required" unless $endpoint && ref($endpoint) eq 'HASH';

    my $dbh = $self->dbh;
    my $e   = $self->escape;
    my $sth = $dbh->prepare(
        "UPDATE ipcm_peers SET ${e}service_endpoint${e} = ? WHERE ${e}id${e} = ?"
    ) or die $dbh->errstr;
    $sth->bind_param(1, $self->{+SERIALIZER}->serialize($endpoint), $self->blob_type);
    $sth->bind_param(2, $peer_id);
    $sth->execute or die $dbh->errstr;
}

sub retract_service_endpoint {
    my $self = shift;
    my ($peer_id) = @_;
    $peer_id //= $self->{+ID};

    my $dbh = $self->dbh;
    my $e   = $self->escape;
    my $sth = $dbh->prepare(
        "UPDATE ipcm_peers SET ${e}service_endpoint${e} = NULL WHERE ${e}id${e} = ?"
    ) or die $dbh->errstr;
    $sth->execute($peer_id) or die $dbh->errstr;
}
```

In each DBI subclass that defines `table_sql` (read each before editing), add a `service_endpoint` column to the `ipcm_peers` schema. Example for SQLite (`lib/IPC/Manager/Client/SQLite.pm`):

```perl
sub table_sql {
    return (
        # ... existing tables ...
        # In the ipcm_peers CREATE TABLE, add:
        # service_endpoint BLOB,
    );
}
```

For each subclass: locate `CREATE TABLE ipcm_peers (...)` and add `${e}service_endpoint${e} BLOB,` (or appropriate type) to the column list.

For migration on existing databases: after `init_db`'s `do($sql)` calls, run:

```perl
sub init_db {
    my $this = shift;
    my $dbh  = $this->dbh(@_);
    my $e    = $this->escape;

    for my $sql ($this->table_sql) {
        local $dbh->{PrintWarn} = 0;
        $dbh->do($sql) or die $dbh->errstr;
    }

    # Best-effort migration: add service_endpoint column if missing.
    # ALTER TABLE ADD COLUMN is idempotent across all four supported
    # dialects when guarded; we simply swallow the error if the column
    # already exists.
    {
        local $@;
        local $dbh->{PrintError} = 0;
        local $dbh->{RaiseError} = 0;
        $dbh->do("ALTER TABLE ipcm_peers ADD COLUMN ${e}service_endpoint${e} BLOB");
    }
}
```

- [ ] **Step 4: PASS**

- [ ] **Step 5: Commit**

```bash
git add lib/IPC/Manager/Base/DBI.pm lib/IPC/Manager/Client/SQLite.pm \
        lib/IPC/Manager/Client/MariaDB.pm lib/IPC/Manager/Client/MySQL.pm \
        lib/IPC/Manager/Client/PostgreSQL.pm \
        t/unit/Client-SQLite.t
git commit -m "Base::DBI: add service_endpoint column with read/write/retract"
```

---

## Phase B — ipcm_info + spawn API

### Task 5: 4-tuple `ipcm_info` parsing

**Files:**
- Modify: `lib/IPC/Manager.pm`
- Test: `t/unit/Manager.t` (create if not present; otherwise extend the closest existing test file — check `ls t/unit | grep -i manager`)

- [ ] **Step 1: Write failing test**

Either in `t/unit/Manager.t` or `t/unit/Spawn.t`:

```perl
subtest parse_cinfo_4tuple => sub {
    my @three = ('IPC::Manager::Client::MessageFiles',
                 'IPC::Manager::Serializer::JSON',
                 '/tmp/r1');
    my @four = (@three, 'IPC::Manager::Client::ServiceUnix');

    my @parsed3 = IPC::Manager::_parse_cinfo([@three]);
    is_deeply(\@parsed3, [@three, undef], '3-tuple parses with undef service_protocol');

    my @parsed4 = IPC::Manager::_parse_cinfo([@four]);
    is_deeply(\@parsed4, [@four], '4-tuple parses with service_protocol');
};
```

- [ ] **Step 2: FAIL**

- [ ] **Step 3: Update `_parse_cinfo`**

In `lib/IPC/Manager.pm`:

```perl
sub _parse_cinfo {
    my $cinfo = shift;

    my ($protocol, $route, $serializer, $service_protocol);

    my $rtype = ref $cinfo;
    if ($rtype eq 'ARRAY') {
        ($protocol, $serializer, $route, $service_protocol) = @$cinfo;
    }
    elsif (!$rtype) {
        my $arr = IPC::Manager::Serializer::JSON->deserialize($cinfo);
        ($protocol, $serializer, $route, $service_protocol) = @$arr;
        $protocol         = _parse_protocol($protocol);
        $serializer       = _parse_serializer($serializer);
        $service_protocol = _parse_protocol($service_protocol) if $service_protocol;
    }
    else {
        croak "Not sure what to do with $cinfo";
    }

    require_mod($protocol);
    require_mod($serializer);
    require_mod($service_protocol) if $service_protocol;

    return ($protocol, $serializer, $route, $service_protocol);
}
```

Update `_connect`:

```perl
sub _connect {
    my ($meth, $id, $cinfo, %params) = @_;

    my ($protocol, $serializer, $route, $service_protocol) = _parse_cinfo($cinfo);

    return $protocol->$meth($id, $serializer, $route, %params)
        unless $service_protocol;

    require IPC::Manager::Client::Composite;
    return IPC::Manager::Client::Composite->$meth(
        $id, $serializer, $route,
        %params,
        main_protocol    => $protocol,
        service_protocol => $service_protocol,
    );
}
```

(`Client::Composite` is implemented in Task 17. Keep this commit even though `Composite` is missing — make the parser change atomic; the import in `_connect` is lazy and only triggers in 4-tuple mode.)

- [ ] **Step 4: PASS**

- [ ] **Step 5: Commit**

```bash
git add lib/IPC/Manager.pm t/unit/Spawn.t
git commit -m "Manager: parse optional 4th element (service_protocol) in ipcm_info"
```

---

### Task 6: `ipcm_spawn` `service_protocol` keyword

**Files:**
- Modify: `lib/IPC/Manager.pm`, `lib/IPC/Manager/Spawn.pm`
- Test: `t/unit/Spawn.t`

- [ ] **Step 1: Write failing test**

```perl
subtest spawn_service_protocol => sub {
    my $spawn = ipcm_spawn(
        protocol         => 'MessageFiles',
        service_protocol => 'ServiceUnix',
        guard            => 0,
    );

    isa_ok($spawn, 'IPC::Manager::Spawn');
    is($spawn->service_protocol, 'IPC::Manager::Client::ServiceUnix', 'service protocol stored');

    my $info = IPC::Manager::Serializer::JSON->deserialize($spawn->info);
    is(scalar @$info, 4, 'info has 4 elements');
    is($info->[3], 'IPC::Manager::Client::ServiceUnix', '4th element is service protocol');

    $spawn->{guard} = 0; # avoid sanity checks at DESTROY
};
```

- [ ] **Step 2: FAIL**

- [ ] **Step 3: Plumb through Spawn**

In `lib/IPC/Manager/Spawn.pm`, add to `Object::HashBase` field list:

```perl
    <service_protocol
```

Update `info()`:

```perl
sub info {
    my $self = shift;
    my @tup = @{$self}{PROTOCOL(), SERIALIZER(), ROUTE()};
    push @tup, $self->{+SERVICE_PROTOCOL} if $self->{+SERVICE_PROTOCOL};
    return IPC::Manager::Serializer::JSON->serialize(\@tup);
}
```

In `lib/IPC/Manager.pm`, update `ipcm_spawn`:

```perl
sub ipcm_spawn {
    my %params = @_;

    my $guard            = delete $params{guard}            // 1;
    my $do_sanity_check  = delete $params{do_sanity_check}  // 0;
    my $debug            = delete $params{debug}            // 0;
    my $serializer       = delete $params{serializer}       // ipcm_default_serializer();
    my $protocol         = delete $params{protocol}         // ipcm_default_protocol();
    my $protocols        = delete $params{protocols}        // ipcm_default_protocol_list();
    my $service_protocol = delete $params{service_protocol};

    if ($protocol) {
        $protocol = _parse_protocol($protocol);
        require_mod($protocol);
    }
    else {
        for my $prot (@$protocols) {
            $prot = _parse_protocol($prot);
            local $@;
            eval { require_mod($prot); $prot->viable } or next;
            $protocol = $prot;
            last;
        }
        croak "Could not find a viable protocol" unless $protocol;
    }

    if ($service_protocol) {
        $service_protocol = _parse_protocol($service_protocol);
        require_mod($service_protocol);
    }

    $serializer = _parse_serializer($serializer);
    require_mod($serializer);

    my ($route, $stash) = $protocol->spawn(%params, serializer => $serializer);

    return IPC::Manager::Spawn->new(
        protocol         => $protocol,
        service_protocol => $service_protocol,
        serializer       => $serializer,
        route            => $route,
        stash            => $stash,
        guard            => $guard,
        do_sanity_check  => $do_sanity_check,
        debug            => $debug,
    );
}
```

- [ ] **Step 4: PASS**

- [ ] **Step 5: Commit**

```bash
git add lib/IPC/Manager.pm lib/IPC/Manager/Spawn.pm t/unit/Spawn.t
git commit -m "Spawn/ipcm_spawn: accept service_protocol; encode in 4th info() element"
```

---

### Task 7: Auth-key env var for exec'd services

**Files:**
- Modify: `lib/IPC/Manager/Spawn.pm`, `lib/IPC/Manager/Service/State.pm`, `lib/IPC/Manager.pm`
- Test: `t/unit/composite_auth_key.t` (new)

- [ ] **Step 1: Write failing test**

`t/unit/composite_auth_key.t`:

```perl
use Test2::V0;
use IPC::Manager qw/ipcm_spawn/;
use Digest::SHA qw/sha256_hex/;

my $spawn = ipcm_spawn(
    protocol => 'MessageFiles',
    guard    => 0,
);

my $key  = $spawn->auth_key;
my $hash = substr(sha256_hex($spawn->route), 0, 16);
my $env  = "IPCM_AUTH_KEY_${hash}";

ok(!defined $ENV{$env}, "env var not set until export_auth_key called");

$spawn->export_auth_key_to_env;
is($ENV{$env}, $key, 'env var set after export');

$spawn->clear_exported_auth_key;
ok(!defined $ENV{$env}, 'env var cleared');

# Process-local registry lookup
is(IPC::Manager::Spawn->lookup_auth_key($spawn->route), $key,
   'route -> auth_key lookup works in-process');

done_testing;
```

- [ ] **Step 2: FAIL**

- [ ] **Step 3: Implement registry + env helpers**

In `lib/IPC/Manager/Spawn.pm`:

Add at top:
```perl
use Digest::SHA qw/sha256_hex/;
```

Add a process-local registry below `use overload`:
```perl
my %AUTH_REG;  # route -> auth_key
```

In `init`, after `$self->{+AUTH_KEY} //= gen_uuid();`, register:
```perl
    $AUTH_REG{$self->{+ROUTE}} = $self->{+AUTH_KEY};
```

Add class method:
```perl
sub lookup_auth_key {
    my $class = shift;
    my ($route) = @_;
    return $AUTH_REG{$route};
}
```

Add helpers:
```perl
sub _env_var_name {
    my $self = shift;
    my $hash = substr(sha256_hex($self->{+ROUTE}), 0, 16);
    return "IPCM_AUTH_KEY_${hash}";
}

sub export_auth_key_to_env {
    my $self = shift;
    $ENV{$self->_env_var_name} = $self->{+AUTH_KEY};
}

sub clear_exported_auth_key {
    my $self = shift;
    delete $ENV{$self->_env_var_name};
}
```

In `lib/IPC/Manager/Service/State.pm`, in `import` (after parsing `$json`):

```perl
    # If the parent exec'd us, retrieve the auth key from env, then clear
    # the env var so the auth key does not leak to grandchildren that did
    # not need it.
    my $route = $params->{ipcm_info};
    if (ref($route) ne 'ARRAY') {
        my $arr = IPC::Manager::Serializer::JSON->deserialize($route);
        $route = $arr->[2];
    }
    else {
        $route = $route->[2];
    }
    my $hash = substr(Digest::SHA::sha256_hex($route), 0, 16);
    my $env  = "IPCM_AUTH_KEY_${hash}";
    if (defined $ENV{$env}) {
        require IPC::Manager::Spawn;
        IPC::Manager::Spawn->_register_auth_key($route, delete $ENV{$env});
    }
```

Add registration helper to `Spawn`:

```perl
sub _register_auth_key {
    my $class = shift;
    my ($route, $key) = @_;
    $AUTH_REG{$route} = $key;
}
```

Add `use Digest::SHA qw/sha256_hex/;` and `use IPC::Manager::Serializer::JSON();` to `Service/State.pm` if not already present.

In `Manager::ipcm_service` (which lives in `Service::State::ipcm_service`), the exec branch needs to set the env var on the parent side before fork+exec. Locate the `if ($exec)` parent block (the parent returns before exec runs in the child) — it already serializes params; insert immediately before `fork()`:

```perl
    if ($exec) {
        # Carry the auth key into the exec'd child via env. Set on the
        # parent so fork() inherits it, clear after fork+exec resumes.
        my $route_for_env = $params{ipcm_info};
        if (ref($route_for_env) ne 'ARRAY') {
            my $arr = IPC::Manager::Serializer::JSON->deserialize($route_for_env);
            $route_for_env = $arr->[2];
        }
        else {
            $route_for_env = $route_for_env->[2];
        }
        my $key = IPC::Manager::Spawn->lookup_auth_key($route_for_env);
        if (defined $key) {
            my $hash = substr(Digest::SHA::sha256_hex($route_for_env), 0, 16);
            $exec->{__env_key} = "IPCM_AUTH_KEY_${hash}";
            $ENV{$exec->{__env_key}} = $key;
        }
    }
```

After the parent-side fork return (where the parent is about to call `$out->ready`), clear:

```perl
        delete $ENV{$exec->{__env_key}} if $exec && $exec->{__env_key};
```

- [ ] **Step 4: PASS**

- [ ] **Step 5: Commit**

```bash
git add lib/IPC/Manager/Spawn.pm lib/IPC/Manager/Service/State.pm \
        t/unit/composite_auth_key.t
git commit -m "Spawn/Service::State: process-local auth-key registry + env hand-off for exec"
```

---

## Phase C — `Base::ServiceSocket` primitives

### Task 8: Frame encode/decode

**Files:**
- Create: `lib/IPC/Manager/Base/ServiceSocket.pm`
- Test: `t/unit/Base-ServiceSocket.t`

- [ ] **Step 1: Write failing test**

`t/unit/Base-ServiceSocket.t`:

```perl
use Test2::V0;
use IPC::Manager::Base::ServiceSocket;

subtest framing => sub {
    my $body = '{"hello":"world"}';
    my $frame = IPC::Manager::Base::ServiceSocket::encode_frame($body);
    is(length($frame), 4 + length($body), 'frame size = 4 + body');

    my $buf = $frame . $frame . substr($frame, 0, 3);
    my @decoded;
    while (defined(my $msg = IPC::Manager::Base::ServiceSocket::decode_frame_from_buffer(\$buf))) {
        push @decoded, $msg;
    }
    is_deeply(\@decoded, [$body, $body], 'two full frames decoded');
    is(length($buf), 3, 'partial third frame remains in buffer');

    # Oversized rejection: anything > 64 MiB raises.
    my $big_len = pack('N', 2**26 + 1);
    my $bad = $big_len . ('x' x 16);
    like(
        dies { IPC::Manager::Base::ServiceSocket::decode_frame_from_buffer(\$bad) },
        qr/oversize/i,
        'oversize frame rejected',
    );
};

done_testing;
```

- [ ] **Step 2: FAIL**

- [ ] **Step 3: Implement frame primitives**

`lib/IPC/Manager/Base/ServiceSocket.pm`:

```perl
package IPC::Manager::Base::ServiceSocket;
use strict;
use warnings;

our $VERSION = '0.000034';

use Carp qw/croak/;

use parent 'IPC::Manager::Client';

# 64 MiB is far past anything realistic and below INT_MAX so we never
# allocate a buffer that pegs the box on a corrupt length prefix.
use constant MAX_FRAME_BYTES => 64 * 1024 * 1024;

sub encode_frame {
    my ($body) = @_;
    return pack('N', length $body) . $body;
}

sub decode_frame_from_buffer {
    my ($buf_ref) = @_;
    return undef unless length($$buf_ref) >= 4;

    my $len = unpack('N', substr($$buf_ref, 0, 4));
    croak "oversize frame ($len bytes)" if $len > MAX_FRAME_BYTES;

    return undef unless length($$buf_ref) >= 4 + $len;

    my $body = substr($$buf_ref, 4, $len);
    substr($$buf_ref, 0, 4 + $len) = '';

    return $body;
}

1;
```

- [ ] **Step 4: PASS**

- [ ] **Step 5: Commit**

```bash
git add lib/IPC/Manager/Base/ServiceSocket.pm t/unit/Base-ServiceSocket.t
git commit -m "Base::ServiceSocket: length-prefixed frame encode/decode"
```

---

### Task 9: HELLO/HELLO_ACK encoding + StreamState

**Files:**
- Modify: `lib/IPC/Manager/Base/ServiceSocket.pm`
- Test: `t/unit/Base-ServiceSocket.t`

- [ ] **Step 1: Write failing test**

Append to `t/unit/Base-ServiceSocket.t`:

```perl
subtest handshake_codec => sub {
    require IPC::Manager::Serializer::JSON;
    my $ser = 'IPC::Manager::Serializer::JSON';

    my $hello = IPC::Manager::Base::ServiceSocket::encode_hello(
        $ser,
        from            => 'svcA',
        auth_key        => 'KEY',
        connection_uuid => 'UUID-1',
    );
    my $msg = IPC::Manager::Base::ServiceSocket::decode_hello($ser, $hello);
    is($msg->{ipcm_hello},      1, 'hello marker');
    is($msg->{from},            'svcA');
    is($msg->{auth_key},        'KEY');
    is($msg->{connection_uuid}, 'UUID-1');

    my $ack = IPC::Manager::Base::ServiceSocket::encode_hello_ack(
        $ser, from => 'svcB', connection_uuid => 'UUID-1',
    );
    my $amsg = IPC::Manager::Base::ServiceSocket::decode_hello($ser, $ack);
    is($amsg->{ipcm_hello_ack}, 1, 'ack marker');
};

subtest stream_state => sub {
    my $st = IPC::Manager::Base::ServiceSocket::StreamState->new(
        peer_id         => 'svcA',
        connection_uuid => 'UUID-1',
        socket          => undef,
    );
    is($st->state, 'handshaking', 'starts handshaking');
    $st->set_state('established');
    is($st->state, 'established', 'transition');
    is($st->peer_id, 'svcA', 'peer_id stored');
};
```

- [ ] **Step 2: FAIL**

- [ ] **Step 3: Implement codec + StreamState**

Append to `lib/IPC/Manager/Base/ServiceSocket.pm`:

```perl
sub encode_hello {
    my ($ser, %fields) = @_;
    my $body = $ser->serialize({
        ipcm_hello      => 1,
        from            => $fields{from},
        auth_key        => $fields{auth_key},
        connection_uuid => $fields{connection_uuid},
    });
    return encode_frame($body);
}

sub encode_hello_ack {
    my ($ser, %fields) = @_;
    my $body = $ser->serialize({
        ipcm_hello_ack  => 1,
        from            => $fields{from},
        connection_uuid => $fields{connection_uuid},
    });
    return encode_frame($body);
}

sub decode_hello {
    my ($ser, $frame_bytes) = @_;
    my $copy = $frame_bytes;
    my $body = decode_frame_from_buffer(\$copy);
    croak "incomplete handshake frame" unless defined $body;

    my $msg;
    croak "malformed handshake frame" unless eval { $msg = $ser->deserialize($body); 1 };
    croak "malformed handshake frame" unless ref($msg) eq 'HASH';
    return $msg;
}
```

Append `StreamState` package (in same file, separate package block):

```perl
package IPC::Manager::Base::ServiceSocket::StreamState;
use strict;
use warnings;

use Object::HashBase qw{
    <peer_id
    +connection_uuid
    <socket
    +state
    +read_buffer
    +outbox
    +handshake_started_at
};

sub init {
    my $self = shift;
    $self->{+STATE}                //= 'handshaking';
    $self->{+READ_BUFFER}          //= '';
    $self->{+OUTBOX}               //= [];
    $self->{+HANDSHAKE_STARTED_AT} //= Time::HiRes::time();
}

sub set_state    { $_[0]->{+STATE} = $_[1] }
sub append_bytes { $_[0]->{+READ_BUFFER} .= $_[1] }
sub queue_outbox { push @{$_[0]->{+OUTBOX}}, $_[1] }

1;
```

Add `use Time::HiRes ();` near top.

- [ ] **Step 4: PASS**

- [ ] **Step 5: Commit**

```bash
git add lib/IPC/Manager/Base/ServiceSocket.pm t/unit/Base-ServiceSocket.t
git commit -m "Base::ServiceSocket: HELLO/HELLO_ACK codec + StreamState"
```

---

### Task 10: Stream pool + accumulators on ServiceSocket

**Files:**
- Modify: `lib/IPC/Manager/Base/ServiceSocket.pm`
- Test: `t/unit/Base-ServiceSocket.t`

- [ ] **Step 1: Write failing test**

```perl
subtest accumulators => sub {
    my $svc = IPC::Manager::Base::ServiceSocket->new_for_test();

    $svc->_record_new_connection('svcA');
    $svc->_record_new_connection('svcB');
    is_deeply([sort @{$svc->take_new_connections}], ['svcA', 'svcB']);
    is_deeply($svc->take_new_connections, [], 'drained on read');

    $svc->_record_lost_connection('svcA');
    is_deeply($svc->take_lost_connections, ['svcA']);

    $svc->_record_rejected_connection({reason => 'bad_key', remote => undef, claimed_from => 'x', at => 1});
    my $rej = $svc->take_rejected_connections;
    is($rej->[0]{reason}, 'bad_key');
    is_deeply($svc->take_rejected_connections, []);
};
```

- [ ] **Step 2: FAIL**

- [ ] **Step 3: Add stream pool + accumulators**

Append to ServiceSocket.pm (the main `IPC::Manager::Base::ServiceSocket` package):

```perl
use Object::HashBase qw{
    +listen_socket
    +streams
    +pending_handshakes
    +acc_new
    +acc_lost
    +acc_rejected
    +auth_key
    +listen_endpoint
    <handshake_timeout
};

sub init {
    my $self = shift;
    $self->SUPER::init();
    $self->{+STREAMS}            //= {};
    $self->{+PENDING_HANDSHAKES} //= {};   # fileno -> StreamState
    $self->{+ACC_NEW}            //= [];
    $self->{+ACC_LOST}           //= [];
    $self->{+ACC_REJECTED}       //= [];
    $self->{+HANDSHAKE_TIMEOUT}  //= 2;
}

sub _record_new_connection      { push @{$_[0]->{+ACC_NEW}},      $_[1] }
sub _record_lost_connection     { push @{$_[0]->{+ACC_LOST}},     $_[1] }
sub _record_rejected_connection { push @{$_[0]->{+ACC_REJECTED}}, $_[1] }

sub take_new_connections      { my $a = $_[0]->{+ACC_NEW};      $_[0]->{+ACC_NEW}      = []; $a }
sub take_lost_connections     { my $a = $_[0]->{+ACC_LOST};     $_[0]->{+ACC_LOST}     = []; $a }
sub take_rejected_connections { my $a = $_[0]->{+ACC_REJECTED}; $_[0]->{+ACC_REJECTED} = []; $a }

# For unit tests only.
sub new_for_test {
    my $class = shift;
    bless {
        STREAMS()            => {},
        PENDING_HANDSHAKES() => {},
        ACC_NEW()            => [],
        ACC_LOST()           => [],
        ACC_REJECTED()       => [],
        HANDSHAKE_TIMEOUT()  => 2,
    }, $class;
}
```

- [ ] **Step 4: PASS**

- [ ] **Step 5: Commit**

```bash
git add lib/IPC/Manager/Base/ServiceSocket.pm t/unit/Base-ServiceSocket.t
git commit -m "Base::ServiceSocket: stream pool + per-cycle accumulator API"
```

---

### Task 11: `accept_pending` + `advance_handshakes` server-side

**Files:**
- Modify: `lib/IPC/Manager/Base/ServiceSocket.pm`
- Test: `t/unit/Base-ServiceSocket.t`

This task implements the server-side handshake. Test it via socketpair / loopback so it does not require ServiceUnix or ServiceIP yet. (Use `IO::Socket->socketpair` for AF_UNIX/SOCK_STREAM pairs.)

- [ ] **Step 1: Write failing test**

```perl
subtest server_handshake => sub {
    use Socket qw/PF_UNIX SOCK_STREAM AF_UNIX/;
    my ($svr, $cli);
    socketpair($svr, $cli, AF_UNIX, SOCK_STREAM, 0) or die "socketpair: $!";
    $_->blocking(0) for $svr, $cli;

    require IPC::Manager::Serializer::JSON;
    my $ser = 'IPC::Manager::Serializer::JSON';

    my $svc = IPC::Manager::Base::ServiceSocket->new_for_test();
    $svc->{auth_key()}    = 'GOOD';
    $svc->{serializer()}  = $ser;
    $svc->_register_pending_socket($svr);

    # Client sends a HELLO with the right key.
    my $hello = IPC::Manager::Base::ServiceSocket::encode_hello(
        $ser, from => 'cli1', auth_key => 'GOOD', connection_uuid => 'U-1',
    );
    syswrite($cli, $hello);

    # Drive the handshake.
    $svc->advance_handshakes;

    is_deeply($svc->take_new_connections, ['cli1'], 'cli1 promoted');
    is_deeply($svc->take_rejected_connections, [], 'no rejections');

    # Client should have received HELLO_ACK.
    sysread($cli, my $ack, 4096);
    my $decoded = IPC::Manager::Base::ServiceSocket::decode_hello($ser, $ack);
    is($decoded->{ipcm_hello_ack}, 1, 'received ack');
};

subtest server_rejects_bad_key => sub {
    use Socket qw/PF_UNIX SOCK_STREAM AF_UNIX/;
    my ($svr, $cli);
    socketpair($svr, $cli, AF_UNIX, SOCK_STREAM, 0) or die "socketpair: $!";
    $_->blocking(0) for $svr, $cli;

    require IPC::Manager::Serializer::JSON;
    my $ser = 'IPC::Manager::Serializer::JSON';

    my $svc = IPC::Manager::Base::ServiceSocket->new_for_test();
    $svc->{auth_key()}   = 'GOOD';
    $svc->{serializer()} = $ser;
    $svc->_register_pending_socket($svr);

    syswrite($cli, IPC::Manager::Base::ServiceSocket::encode_hello(
        $ser, from => 'cli1', auth_key => 'BAD', connection_uuid => 'U-2',
    ));

    $svc->advance_handshakes;

    is_deeply($svc->take_new_connections, [], 'no promotion');
    my $rej = $svc->take_rejected_connections;
    is($rej->[0]{reason}, 'bad_key');
    is($rej->[0]{claimed_from}, 'cli1');
};
```

- [ ] **Step 2: FAIL**

- [ ] **Step 3: Implement**

Append to `lib/IPC/Manager/Base/ServiceSocket.pm` (main package):

```perl
use Time::HiRes qw/time/;

sub _register_pending_socket {
    my $self = shift;
    my ($sock, %extra) = @_;
    my $st = IPC::Manager::Base::ServiceSocket::StreamState->new(
        socket => $sock,
        peer_id => undef,
        connection_uuid => undef,
        %extra,
    );
    $self->{+PENDING_HANDSHAKES}->{fileno($sock)} = $st;
}

sub _drain_handshake_buffer {
    my ($self, $st) = @_;
    my $sock = $st->socket;

    while (1) {
        my $chunk;
        my $n = sysread($sock, $chunk, 65536);
        last unless defined $n && $n > 0;
        $st->append_bytes($chunk);
    }
}

sub _remote_info {
    my ($self, $sock) = @_;
    return undef;  # subclasses override (Unix vs IP)
}

sub advance_handshakes {
    my $self = shift;
    my $now  = time;
    my $ser  = $self->{+SERIALIZER};

    for my $fno (keys %{$self->{+PENDING_HANDSHAKES}}) {
        my $st = $self->{+PENDING_HANDSHAKES}->{$fno};

        # Timeout check.
        if ($now - $st->handshake_started_at > $self->{+HANDSHAKE_TIMEOUT}) {
            $self->_record_rejected_connection({
                reason       => 'handshake_timeout',
                claimed_from => undef,
                remote       => $self->_remote_info($st->socket),
                at           => $now,
            });
            close($st->socket);
            delete $self->{+PENDING_HANDSHAKES}->{$fno};
            next;
        }

        $self->_drain_handshake_buffer($st);

        # Try to decode a complete frame.
        my $body;
        my $err;
        unless (eval {
            my $buf = $st->{+IPC::Manager::Base::ServiceSocket::StreamState::READ_BUFFER()};
            $body = decode_frame_from_buffer(\$buf);
            $st->{+IPC::Manager::Base::ServiceSocket::StreamState::READ_BUFFER()} = $buf;
            1;
        }) {
            $err = $@;
        }

        if ($err) {
            $self->_record_rejected_connection({
                reason       => 'malformed_hello',
                claimed_from => undef,
                remote       => $self->_remote_info($st->socket),
                at           => $now,
            });
            close($st->socket);
            delete $self->{+PENDING_HANDSHAKES}->{$fno};
            next;
        }

        next unless defined $body;  # not enough bytes yet

        my $msg;
        unless (eval { $msg = $ser->deserialize($body); ref($msg) eq 'HASH' }) {
            $self->_record_rejected_connection({
                reason       => 'malformed_hello',
                claimed_from => undef,
                remote       => $self->_remote_info($st->socket),
                at           => $now,
            });
            close($st->socket);
            delete $self->{+PENDING_HANDSHAKES}->{$fno};
            next;
        }

        my $reason;
        if (!defined $msg->{auth_key}) {
            $reason = 'missing_key';
        }
        elsif ($msg->{auth_key} ne ($self->{+AUTH_KEY} // '')) {
            $reason = 'bad_key';
        }

        if ($reason) {
            $self->_record_rejected_connection({
                reason       => $reason,
                claimed_from => $msg->{from},
                remote       => $self->_remote_info($st->socket),
                at           => $now,
            });
            close($st->socket);
            delete $self->{+PENDING_HANDSHAKES}->{$fno};
            next;
        }

        my $peer = $msg->{from};
        my $cuuid = $msg->{connection_uuid};

        # Duplicate-stream race: keep lower connection_uuid.
        if (my $existing = $self->{+STREAMS}->{$peer}) {
            if ($cuuid lt $existing->connection_uuid) {
                close($existing->socket);
                $self->{+STREAMS}->{$peer} = $st;
                $self->_record_lost_connection($peer);  # the old one is gone
            }
            else {
                close($st->socket);
                delete $self->{+PENDING_HANDSHAKES}->{$fno};
                next;
            }
        }
        else {
            $self->{+STREAMS}->{$peer} = $st;
        }

        # Send HELLO_ACK.
        my $ack = encode_hello_ack(
            $ser, from => $self->{+ID}, connection_uuid => $cuuid,
        );
        syswrite($st->socket, $ack);

        $st->{+IPC::Manager::Base::ServiceSocket::StreamState::PEER_ID()}         = $peer;
        $st->{+IPC::Manager::Base::ServiceSocket::StreamState::CONNECTION_UUID()} = $cuuid;
        $st->set_state('established');

        delete $self->{+PENDING_HANDSHAKES}->{$fno};
        $self->_record_new_connection($peer);
    }
}
```

(Note: the `+` field-access constants on `StreamState` need to be exported via `Object::HashBase` — they already are via the `+peer_id`/`+connection_uuid`/`+read_buffer` declarations.)

- [ ] **Step 4: PASS**

- [ ] **Step 5: Commit**

```bash
git add lib/IPC/Manager/Base/ServiceSocket.pm t/unit/Base-ServiceSocket.t
git commit -m "Base::ServiceSocket: server-side accept handshake state machine"
```

---

### Task 12: `accept_pending` (drain listen socket)

**Files:**
- Modify: `lib/IPC/Manager/Base/ServiceSocket.pm`
- Test: `t/unit/Base-ServiceSocket.t`

- [ ] **Step 1: Write failing test**

```perl
subtest accept_pending => sub {
    skip_all 'Need IO::Socket::UNIX' unless eval { require IO::Socket::UNIX; 1 };

    my $tmp = File::Temp::tempdir(CLEANUP => 1);
    my $path = "$tmp/listen.sock";

    my $listen = IO::Socket::UNIX->new(
        Type => Socket::SOCK_STREAM(),
        Local => $path,
        Listen => 8,
    ) or die "listen: $!";
    $listen->blocking(0);

    my $svc = IPC::Manager::Base::ServiceSocket->new_for_test();
    $svc->{listen_socket()} = $listen;

    my $c1 = IO::Socket::UNIX->new(Type => Socket::SOCK_STREAM(), Peer => $path) or die "$!";
    my $c2 = IO::Socket::UNIX->new(Type => Socket::SOCK_STREAM(), Peer => $path) or die "$!";

    $svc->accept_pending;
    is(scalar keys %{$svc->{pending_handshakes()}}, 2, 'two pending handshakes');
};
```

- [ ] **Step 2: FAIL**

- [ ] **Step 3: Implement**

```perl
sub accept_pending {
    my $self = shift;
    my $listen = $self->{+LISTEN_SOCKET} or return;

    while (1) {
        my $sock = $listen->accept;
        last unless $sock;
        $sock->blocking(0);
        $self->_register_pending_socket($sock);
    }
}
```

- [ ] **Step 4: PASS**

- [ ] **Step 5: Commit**

```bash
git add lib/IPC/Manager/Base/ServiceSocket.pm t/unit/Base-ServiceSocket.t
git commit -m "Base::ServiceSocket: accept_pending drains listen socket"
```

---

### Task 13: Dial side (`dial`) + client-side handshake

**Files:**
- Modify: `lib/IPC/Manager/Base/ServiceSocket.pm`
- Test: `t/unit/Base-ServiceSocket.t`

- [ ] **Step 1: Write failing test**

End-to-end: a server `Base::ServiceSocket` accepts; a client `Base::ServiceSocket` dials. Use Unix sockets via raw `IO::Socket::UNIX` (avoid depending on the not-yet-built ServiceUnix subclass).

```perl
subtest dial_round_trip => sub {
    skip_all 'Need IO::Socket::UNIX' unless eval { require IO::Socket::UNIX; 1 };

    my $tmp = File::Temp::tempdir(CLEANUP => 1);
    my $path = "$tmp/listen.sock";

    require IPC::Manager::Serializer::JSON;
    my $ser = 'IPC::Manager::Serializer::JSON';

    my $listen = IO::Socket::UNIX->new(
        Type => Socket::SOCK_STREAM(), Local => $path, Listen => 8,
    ) or die $!;
    $listen->blocking(0);

    my $server = IPC::Manager::Base::ServiceSocket->new_for_test();
    $server->{id()}             = 'svcA';
    $server->{auth_key()}       = 'KEY';
    $server->{serializer()}     = $ser;
    $server->{listen_socket()}  = $listen;

    my $client = IPC::Manager::Base::ServiceSocket->new_for_test();
    $client->{id()}             = 'cliA';
    $client->{auth_key()}       = 'KEY';
    $client->{serializer()}     = $ser;

    # Dial.
    my $stream = $client->dial_unix(
        peer_id  => 'svcA',
        path     => $path,
    );

    # Drive both sides until handshake completes.
    for (1..10) {
        $server->accept_pending;
        $server->advance_handshakes;
        $client->advance_dials;
        last if $client->{streams()}->{svcA};
    }

    is_deeply($server->take_new_connections, ['cliA'], 'server saw cliA');
    ok($client->{streams()}->{svcA}, 'client established stream');
};
```

- [ ] **Step 2: FAIL**

- [ ] **Step 3: Implement `dial_unix` and `advance_dials`**

```perl
use Test2::Util::UUID qw/gen_uuid/;
use Socket qw/PF_UNIX SOCK_STREAM/;

sub dial_unix {
    my $self = shift;
    my (%params) = @_;
    croak "'peer_id' required" unless $params{peer_id};
    croak "'path' required"    unless $params{path};

    my $sock = IO::Socket::UNIX->new(
        Type => SOCK_STREAM,
        Peer => $params{path},
    ) or die "dial '$params{path}': $!";
    $sock->blocking(0);

    my $cuuid = gen_uuid();
    my $st = IPC::Manager::Base::ServiceSocket::StreamState->new(
        socket          => $sock,
        peer_id         => $params{peer_id},
        connection_uuid => $cuuid,
    );

    # Send HELLO immediately.
    my $hello = encode_hello(
        $self->{+SERIALIZER},
        from            => $self->{+ID},
        auth_key        => $self->{+AUTH_KEY},
        connection_uuid => $cuuid,
    );
    syswrite($sock, $hello);

    $self->{+PENDING_HANDSHAKES}->{fileno($sock)} = $st;
    return $st;
}

sub dial_inet {
    my $self = shift;
    my (%params) = @_;
    croak "'peer_id' required" unless $params{peer_id};
    croak "'host' / 'port' required" unless $params{host} && $params{port};

    require IO::Socket::INET;
    my $sock = IO::Socket::INET->new(
        PeerHost => $params{host},
        PeerPort => $params{port},
        Proto    => 'tcp',
    ) or die "dial $params{host}:$params{port}: $!";
    $sock->blocking(0);

    my $cuuid = gen_uuid();
    my $st = IPC::Manager::Base::ServiceSocket::StreamState->new(
        socket          => $sock,
        peer_id         => $params{peer_id},
        connection_uuid => $cuuid,
    );

    my $hello = encode_hello(
        $self->{+SERIALIZER},
        from            => $self->{+ID},
        auth_key        => $self->{+AUTH_KEY},
        connection_uuid => $cuuid,
    );
    syswrite($sock, $hello);

    $self->{+PENDING_HANDSHAKES}->{fileno($sock)} = $st;
    return $st;
}

sub advance_dials {
    my $self = shift;
    my $now  = time;
    my $ser  = $self->{+SERIALIZER};

    for my $fno (keys %{$self->{+PENDING_HANDSHAKES}}) {
        my $st = $self->{+PENDING_HANDSHAKES}->{$fno};
        next unless defined $st->peer_id;  # accept-side has no peer_id yet

        # Timeout
        if ($now - $st->handshake_started_at > $self->{+HANDSHAKE_TIMEOUT}) {
            $self->_record_lost_connection($st->peer_id);
            close($st->socket);
            delete $self->{+PENDING_HANDSHAKES}->{$fno};
            next;
        }

        $self->_drain_handshake_buffer($st);

        my $body;
        eval {
            my $buf = $st->{+IPC::Manager::Base::ServiceSocket::StreamState::READ_BUFFER()};
            $body = decode_frame_from_buffer(\$buf);
            $st->{+IPC::Manager::Base::ServiceSocket::StreamState::READ_BUFFER()} = $buf;
            1;
        } or do {
            $self->_record_lost_connection($st->peer_id);
            close($st->socket);
            delete $self->{+PENDING_HANDSHAKES}->{$fno};
            next;
        };

        next unless defined $body;

        my $msg;
        unless (eval { $msg = $ser->deserialize($body); ref($msg) eq 'HASH' }) {
            $self->_record_lost_connection($st->peer_id);
            close($st->socket);
            delete $self->{+PENDING_HANDSHAKES}->{$fno};
            next;
        }

        unless ($msg->{ipcm_hello_ack} && $msg->{connection_uuid} eq $st->connection_uuid) {
            $self->_record_lost_connection($st->peer_id);
            close($st->socket);
            delete $self->{+PENDING_HANDSHAKES}->{$fno};
            next;
        }

        # Promote (with duplicate-race resolution as in advance_handshakes).
        if (my $existing = $self->{+STREAMS}->{$st->peer_id}) {
            if ($st->connection_uuid lt $existing->connection_uuid) {
                close($existing->socket);
                $self->{+STREAMS}->{$st->peer_id} = $st;
                $self->_record_lost_connection($st->peer_id);
            }
            else {
                close($st->socket);
                delete $self->{+PENDING_HANDSHAKES}->{$fno};
                next;
            }
        }
        else {
            $self->{+STREAMS}->{$st->peer_id} = $st;
        }

        $st->set_state('established');
        delete $self->{+PENDING_HANDSHAKES}->{$fno};
        $self->_record_new_connection($st->peer_id);
    }
}
```

- [ ] **Step 4: PASS**

- [ ] **Step 5: Commit**

```bash
git add lib/IPC/Manager/Base/ServiceSocket.pm t/unit/Base-ServiceSocket.t
git commit -m "Base::ServiceSocket: dial + client-side handshake (advance_dials)"
```

---

### Task 14: Stream `drain_stream` + `send_message`

**Files:**
- Modify: `lib/IPC/Manager/Base/ServiceSocket.pm`
- Test: `t/unit/Base-ServiceSocket.t`

- [ ] **Step 1: Write failing test**

After establishing a server+client pair (extend the previous test):

```perl
subtest stream_messages => sub {
    # ... reuse the dial_round_trip setup from above ...
    # then:

    $client->send_stream_message('svcA', { hello => 'world' });
    $server->drain_stream($server->{streams()}->{cliA});
    my @msgs = $server->take_stream_messages('cliA');
    is(scalar @msgs, 1);
    isa_ok($msgs[0], 'IPC::Manager::Message');
    is_deeply($msgs[0]->content, { hello => 'world' });
};
```

- [ ] **Step 2: FAIL**

- [ ] **Step 3: Implement**

```perl
sub send_stream_message {
    my $self = shift;
    my ($peer_id, $payload, %extra) = @_;

    my $st = $self->{+STREAMS}->{$peer_id}
        or croak "No established stream to '$peer_id'";

    my $msg = ref($payload) && eval { $payload->isa('IPC::Manager::Message') }
        ? $payload
        : IPC::Manager::Message->new(
            from    => $self->{+ID},
            to      => $peer_id,
            content => $payload,
            %extra,
        );

    my $body  = $self->{+SERIALIZER}->serialize($msg);
    my $frame = encode_frame($body);

    my $written = syswrite($st->socket, $frame);
    if (!defined $written || $written < length($frame)) {
        my $remainder = defined $written ? substr($frame, $written) : $frame;
        $st->queue_outbox($remainder);
    }

    $self->{+STATS}->{sent}->{$peer_id}++;
}

sub drain_stream {
    my $self = shift;
    my ($st) = @_;
    my $sock = $st->socket;

    while (1) {
        my $chunk;
        my $n = sysread($sock, $chunk, 65536);
        last unless defined $n;
        if ($n == 0) {
            $self->_record_lost_connection($st->peer_id);
            close($sock);
            delete $self->{+STREAMS}->{$st->peer_id};
            return;
        }
        $st->append_bytes($chunk);
    }

    push @{$self->{_pending_msgs}->{$st->peer_id}}, $self->_pull_complete_messages($st);
}

sub _pull_complete_messages {
    my ($self, $st) = @_;
    my @out;

    while (1) {
        my $body;
        my $err;
        unless (eval {
            my $buf = $st->{+IPC::Manager::Base::ServiceSocket::StreamState::READ_BUFFER()};
            $body = decode_frame_from_buffer(\$buf);
            $st->{+IPC::Manager::Base::ServiceSocket::StreamState::READ_BUFFER()} = $buf;
            1;
        }) {
            $err = $@;
        }

        if ($err) {
            $self->_record_lost_connection($st->peer_id);
            close($st->socket);
            delete $self->{+STREAMS}->{$st->peer_id};
            last;
        }

        last unless defined $body;

        my $msg = IPC::Manager::Message->new(
            $self->{+SERIALIZER}->deserialize($body),
        );
        $self->{+STATS}->{read}->{$msg->{from}}++;
        push @out, $msg;
    }

    return @out;
}

sub take_stream_messages {
    my $self = shift;
    my ($peer_id) = @_;
    my $bucket = delete $self->{_pending_msgs}->{$peer_id};
    return @{$bucket || []};
}

sub take_all_stream_messages {
    my $self = shift;
    my @out;
    for my $peer (keys %{$self->{_pending_msgs} || {}}) {
        push @out, $self->take_stream_messages($peer);
    }
    return @out;
}

sub drain_all_streams {
    my $self = shift;
    my (%params) = @_;
    my $select = $params{select};

    for my $st (values %{$self->{+STREAMS}}) {
        next if $select && !$select->exists($st->socket);
        $self->drain_stream($st);
    }
}

sub flush_outboxes {
    my $self = shift;

    for my $st (values %{$self->{+STREAMS}}) {
        my $obx = $st->{+IPC::Manager::Base::ServiceSocket::StreamState::OUTBOX()} or next;
        while (@$obx) {
            my $written = syswrite($st->socket, $obx->[0]);
            last unless defined $written && $written > 0;
            if ($written == length($obx->[0])) {
                shift @$obx;
            }
            else {
                $obx->[0] = substr($obx->[0], $written);
                last;
            }
        }
    }
}
```

- [ ] **Step 4: PASS**

- [ ] **Step 5: Commit**

```bash
git add lib/IPC/Manager/Base/ServiceSocket.pm t/unit/Base-ServiceSocket.t
git commit -m "Base::ServiceSocket: stream send/drain + outbox flush"
```

---

### Task 15: `handles_for_select` on ServiceSocket

**Files:**
- Modify: `lib/IPC/Manager/Base/ServiceSocket.pm`
- Test: `t/unit/Base-ServiceSocket.t`

- [ ] **Step 1: Write failing test**

```perl
subtest handles_for_select => sub {
    my $svc = IPC::Manager::Base::ServiceSocket->new_for_test();
    $svc->{listen_socket()} = \*STDIN;  # any fh-like, not actually used

    is_deeply([$svc->handles_for_select], [\*STDIN], 'listen-only set');

    # add a fake established stream
    my $fake_sock = \*STDOUT;
    my $st = IPC::Manager::Base::ServiceSocket::StreamState->new(
        socket => $fake_sock, peer_id => 'p',
    );
    $svc->{streams()}->{p} = $st;
    is_deeply(
        [sort { "$a" cmp "$b" } $svc->handles_for_select],
        [sort { "$a" cmp "$b" } \*STDIN, $fake_sock],
        'listen + stream',
    );
};
```

- [ ] **Step 2: FAIL**

- [ ] **Step 3: Implement**

```perl
sub have_handles_for_select { 1 }

sub handles_for_select {
    my $self = shift;
    my @h;
    push @h, $self->{+LISTEN_SOCKET} if $self->{+LISTEN_SOCKET};
    push @h, $_->socket for values %{$self->{+PENDING_HANDSHAKES}};
    push @h, $_->socket for values %{$self->{+STREAMS}};
    return @h;
}
```

- [ ] **Step 4: PASS**

- [ ] **Step 5: Commit**

```bash
git add lib/IPC/Manager/Base/ServiceSocket.pm t/unit/Base-ServiceSocket.t
git commit -m "Base::ServiceSocket: handles_for_select unions listen + streams"
```

---

## Phase D — `ServiceUnix` and `ServiceIP` subclasses

### Task 16: `ServiceUnix`

**Files:**
- Create: `lib/IPC/Manager/Client/ServiceUnix.pm`
- Test: `t/unit/Client-ServiceUnix.t`

- [ ] **Step 1: Write failing test**

```perl
use Test2::V0;
use IO::Socket::UNIX 1.55;
use File::Temp;

use IPC::Manager::Client::ServiceUnix;

my $tmp = File::Temp::tempdir(CLEANUP => 1);

my $svc = IPC::Manager::Client::ServiceUnix->new(
    id         => 'svcA',
    route      => $tmp,
    serializer => 'IPC::Manager::Serializer::JSON',
    auth_key   => 'KEY',
);

$svc->start_listener;
ok(-S "$tmp/svcA.sock", 'unix listener exists');

my $endpoint = $svc->listen_endpoint;
is($endpoint->{type}, 'unix');
is($endpoint->{path}, "$tmp/svcA.sock");

$svc->disconnect;
ok(!-S "$tmp/svcA.sock", 'cleaned up on disconnect');

done_testing;
```

- [ ] **Step 2: FAIL**

- [ ] **Step 3: Implement**

```perl
package IPC::Manager::Client::ServiceUnix;
use strict;
use warnings;

our $VERSION = '0.000034';

use Carp qw/croak/;
use File::Spec;
use IO::Socket::UNIX 1.55;
use Socket qw/SOCK_STREAM/;

use parent 'IPC::Manager::Base::ServiceSocket';
use Object::HashBase qw{
    +listen_path
};

sub _viable { require IO::Socket::UNIX; IO::Socket::UNIX->VERSION('1.55'); 1 }

# Composite-only; no peer-discovery responsibilities here.
sub suspend_supported { 0 }
sub suspend { croak "suspend is not supported by ServiceUnix" }

sub start_listener {
    my $self = shift;
    return if $self->{+LISTEN_SOCKET};

    my $path = File::Spec->catfile(
        $self->{+ROUTE},
        $self->{+ID} . '.sock',
    );
    unlink $path;  # tolerate stale

    my $sock = IO::Socket::UNIX->new(
        Type   => SOCK_STREAM,
        Local  => $path,
        Listen => 64,
    ) or die "ServiceUnix listen on '$path': $!";
    $sock->blocking(0);

    $self->{+LISTEN_SOCKET}   = $sock;
    $self->{+LISTEN_PATH}     = $path;
    $self->{+LISTEN_ENDPOINT} = { type => 'unix', path => $path };
}

sub _remote_info {
    # Unix sockets have no useful remote address.
    return { type => 'unix' };
}

sub dial_endpoint {
    my $self = shift;
    my (%params) = @_;
    return $self->dial_unix(
        peer_id => $params{peer_id},
        path    => $params{endpoint}->{path},
    );
}

sub stop_listener {
    my $self = shift;
    return unless $self->{+LISTEN_SOCKET};
    close(delete $self->{+LISTEN_SOCKET});
    if (my $p = delete $self->{+LISTEN_PATH}) {
        unlink $p;
    }
    delete $self->{+LISTEN_ENDPOINT};
}

sub disconnect {
    my $self = shift;
    $self->stop_listener;
    $self->SUPER::disconnect(@_);
}

sub init {
    my $self = shift;
    # Skip Base::FS init — we are not a full filesystem driver, just a
    # transport. Composite owns route/id semantics.
    $self->IPC::Manager::Client::init();
}

1;
```

- [ ] **Step 4: PASS**

- [ ] **Step 5: Commit**

```bash
git add lib/IPC/Manager/Client/ServiceUnix.pm t/unit/Client-ServiceUnix.t
git commit -m "Client::ServiceUnix: SOCK_STREAM listener over Base::ServiceSocket"
```

---

### Task 17: `ServiceIP`

**Files:**
- Create: `lib/IPC/Manager/Client/ServiceIP.pm`
- Test: `t/unit/Client-ServiceIP.t`

- [ ] **Step 1: Write failing test**

```perl
use Test2::V0;
use IO::Socket::INET;
use IPC::Manager::Client::ServiceIP;

my $svc = IPC::Manager::Client::ServiceIP->new(
    id         => 'svcA',
    route      => '/tmp',
    serializer => 'IPC::Manager::Serializer::JSON',
    auth_key   => 'KEY',
);

$svc->start_listener;
my $ep = $svc->listen_endpoint;
is($ep->{type}, 'tcp');
is($ep->{host}, '127.0.0.1');
ok($ep->{port} > 0, 'ephemeral port assigned');

# Verify another process can connect.
my $cli = IO::Socket::INET->new(
    PeerHost => $ep->{host}, PeerPort => $ep->{port}, Proto => 'tcp',
) or die "$!";
ok($cli->connected, 'tcp connect succeeds');

$svc->disconnect;

done_testing;
```

- [ ] **Step 2: FAIL**

- [ ] **Step 3: Implement**

```perl
package IPC::Manager::Client::ServiceIP;
use strict;
use warnings;

our $VERSION = '0.000034';

use Carp qw/croak/;
use IO::Socket::INET;

use parent 'IPC::Manager::Base::ServiceSocket';
use Object::HashBase qw{
    <service_bind
    <service_port
    <service_inet6
};

sub _viable { require IO::Socket::INET; 1 }

sub suspend_supported { 0 }
sub suspend { croak "suspend is not supported by ServiceIP" }

sub init {
    my $self = shift;
    $self->{+SERVICE_BIND}  //= '127.0.0.1';
    $self->{+SERVICE_PORT}  //= 0;
    $self->{+SERVICE_INET6} //= 0;
    $self->IPC::Manager::Client::init();
}

sub start_listener {
    my $self = shift;
    return if $self->{+LISTEN_SOCKET};

    my $sock_class = $self->{+SERVICE_INET6}
        ? do { require IO::Socket::INET6; 'IO::Socket::INET6' }
        : 'IO::Socket::INET';

    my $sock = $sock_class->new(
        LocalAddr => $self->{+SERVICE_BIND},
        LocalPort => $self->{+SERVICE_PORT},
        Listen    => 64,
        Proto     => 'tcp',
        ReuseAddr => 1,
    ) or die "ServiceIP listen on $self->{+SERVICE_BIND}:$self->{+SERVICE_PORT}: $!";
    $sock->blocking(0);

    $self->{+LISTEN_SOCKET}   = $sock;
    $self->{+LISTEN_ENDPOINT} = {
        type => 'tcp',
        host => $self->{+SERVICE_BIND},
        port => $sock->sockport,
    };
}

sub _remote_info {
    my ($self, $sock) = @_;
    return undef unless $sock && $sock->can('peerhost');
    return { type => 'tcp', host => scalar $sock->peerhost, port => scalar $sock->peerport };
}

sub dial_endpoint {
    my $self = shift;
    my (%params) = @_;
    my $ep = $params{endpoint};
    return $self->dial_inet(
        peer_id => $params{peer_id},
        host    => $ep->{host},
        port    => $ep->{port},
    );
}

sub stop_listener {
    my $self = shift;
    return unless $self->{+LISTEN_SOCKET};
    close(delete $self->{+LISTEN_SOCKET});
    delete $self->{+LISTEN_ENDPOINT};
}

sub disconnect {
    my $self = shift;
    $self->stop_listener;
    $self->SUPER::disconnect(@_);
}

1;
```

- [ ] **Step 4: PASS**

- [ ] **Step 5: Commit**

```bash
git add lib/IPC/Manager/Client/ServiceIP.pm t/unit/Client-ServiceIP.t
git commit -m "Client::ServiceIP: TCP listener over Base::ServiceSocket"
```

---

## Phase E — Composite client

### Task 18: `Composite` skeleton + pass-through

**Files:**
- Create: `lib/IPC/Manager/Client/Composite.pm`
- Test: `t/unit/Client-Composite.t`

- [ ] **Step 1: Write failing test**

```perl
use Test2::V0;
use File::Temp;
use IPC::Manager qw/ipcm_spawn/;

my $tmp_spawn = ipcm_spawn(
    protocol         => 'MessageFiles',
    service_protocol => 'ServiceUnix',
    guard            => 0,
);

my $info = $tmp_spawn->info;

my $c1 = IPC::Manager::ipcm_connect('peer1', $info, auth_key => $tmp_spawn->auth_key);
isa_ok($c1, 'IPC::Manager::Client::Composite');

# Pass-through: peers() works without any service started.
my @peers = $c1->peers;
ok(!@peers, 'no other peers yet (only self)');

$c1->disconnect;
$tmp_spawn->shutdown;

done_testing;
```

- [ ] **Step 2: FAIL**

- [ ] **Step 3: Implement skeleton**

```perl
package IPC::Manager::Client::Composite;
use strict;
use warnings;

our $VERSION = '0.000034';

use Carp qw/croak/;
use Scalar::Util qw/blessed/;

use parent 'IPC::Manager::Client';
use Object::HashBase qw{
    <main
    <service
    +main_protocol
    +service_protocol
    +auth_key_for_dials
};

sub _viable { 1 }

sub connect {
    my $class = shift;
    my ($id, $serializer, $route, %params) = @_;

    my $main_protocol    = delete $params{main_protocol};
    my $service_protocol = delete $params{service_protocol};
    my $auth_key         = delete $params{auth_key};

    croak "main_protocol required"    unless $main_protocol;
    croak "service_protocol required" unless $service_protocol;

    require_mod($main_protocol);
    require_mod($service_protocol);

    my $main = $main_protocol->connect($id, $serializer, $route, %params);

    # Resolve auth_key from caller > registry.
    unless ($auth_key) {
        require IPC::Manager::Spawn;
        $auth_key = IPC::Manager::Spawn->lookup_auth_key($route);
    }

    my $service = $service_protocol->new(
        id         => $id,
        route      => $route,
        serializer => $serializer,
        auth_key   => $auth_key,
    );

    return $class->new(
        id                 => $id,
        route              => $route,
        serializer         => $serializer,
        main               => $main,
        service            => $service,
        main_protocol      => $main_protocol,
        service_protocol   => $service_protocol,
        auth_key_for_dials => $auth_key,
    );
}

sub reconnect {
    my $class = shift;
    return $class->connect(@_, reconnect => 1);
}

sub init {
    my $self = shift;
    croak "'main' is required"    unless $self->{+MAIN};
    croak "'service' is required" unless $self->{+SERVICE};
    # SUPER::init validates id/route/serializer, registers in @LOCAL,
    # and seeds STATS. Composite duplicates the LOCAL registration with
    # main, which is fine - multiple clients per route is allowed.
    $self->SUPER::init();
}

# --- Pass-through to main ---
for my $m (qw/peers peer_pid peer_exists all_stats read_stats write_stats
              peer_service_endpoint publish_service_endpoint
              retract_service_endpoint
              have_handles_for_peer_change handles_for_peer_change
              reset_handles_for_peer_change/) {
    no strict 'refs';
    *$m = sub { my $self = shift; $self->{+MAIN}->$m(@_) };
}

sub disconnect {
    my $self = shift;
    eval { $self->{+SERVICE}->disconnect; 1 } or warn $@;
    eval { $self->{+MAIN}->retract_service_endpoint($self->{+ID}); 1 } or warn $@;
    $self->{+MAIN}->disconnect;
}

sub require_mod {
    require IPC::Manager::Util;
    IPC::Manager::Util::require_mod(@_);
}

1;
```

- [ ] **Step 4: PASS**

- [ ] **Step 5: Commit**

```bash
git add lib/IPC/Manager/Client/Composite.pm t/unit/Client-Composite.t
git commit -m "Client::Composite: skeleton with pass-through to main driver"
```

---

### Task 19: Composite `send_message` dispatch

**Files:**
- Modify: `lib/IPC/Manager/Client/Composite.pm`
- Test: `t/unit/Client-Composite.t`

- [ ] **Step 1: Write failing test**

```perl
subtest dispatch_main => sub {
    # Two composite peers, neither has a service running -> all traffic
    # via main driver.
    my $sp = ipcm_spawn(protocol => 'MessageFiles', service_protocol => 'ServiceUnix', guard => 0);
    my $a = IPC::Manager::ipcm_connect('a', $sp->info, auth_key => $sp->auth_key);
    my $b = IPC::Manager::ipcm_connect('b', $sp->info, auth_key => $sp->auth_key);

    $a->send_message('b', { hi => 1 });
    my @m = $b->get_messages;
    is(scalar @m, 1, 'main path delivers');

    $a->disconnect;
    $b->disconnect;
};
```

- [ ] **Step 2: FAIL** (composite has no `send_message` yet — fails with "Not Implemented" or similar.)

- [ ] **Step 3: Implement**

```perl
sub send_message {
    my $self = shift;
    my $msg  = $self->build_message(@_);

    my $peer = $msg->to or croak "Message has no peer";

    my $endpoint = $self->{+MAIN}->peer_service_endpoint($peer);
    if ($endpoint) {
        $self->_ensure_stream($peer, $endpoint);
        return $self->{+SERVICE}->send_stream_message($peer, $msg);
    }

    return $self->{+MAIN}->send_message($msg);
}

sub _ensure_stream {
    my $self = shift;
    my ($peer_id, $endpoint) = @_;

    return if $self->{+SERVICE}->{streams()}->{$peer_id};

    if ($endpoint->{type} eq 'unix') {
        $self->{+SERVICE}->dial_endpoint(peer_id => $peer_id, endpoint => $endpoint);
    }
    elsif ($endpoint->{type} eq 'tcp') {
        $self->{+SERVICE}->dial_endpoint(peer_id => $peer_id, endpoint => $endpoint);
    }
    else {
        croak "Unknown service endpoint type '$endpoint->{type}'";
    }

    # Drive client-side handshake to completion synchronously up to the
    # service's handshake_timeout. The full event loop will pick this up
    # in the steady state, but the very first send needs a stream that
    # is at least handshake-complete before we can write a message frame
    # on it.
    my $deadline = Time::HiRes::time() + ($self->{+SERVICE}->handshake_timeout // 2);
    while (!$self->{+SERVICE}->{streams()}->{$peer_id}
           && Time::HiRes::time() < $deadline)
    {
        $self->{+SERVICE}->advance_dials;
        IPC::Manager::Util::tinysleep(0.005);
    }

    croak "Failed to establish stream to '$peer_id'"
        unless $self->{+SERVICE}->{streams()}->{$peer_id};
}
```

Add at top: `use Time::HiRes; use IPC::Manager::Util;`.

- [ ] **Step 4: PASS**

- [ ] **Step 5: Commit**

```bash
git add lib/IPC/Manager/Client/Composite.pm t/unit/Client-Composite.t
git commit -m "Client::Composite: send_message dispatches by peer endpoint"
```

---

### Task 20: Composite `get_messages` + `handles_for_select`

**Files:**
- Modify: `lib/IPC/Manager/Client/Composite.pm`
- Test: `t/unit/Client-Composite.t`

- [ ] **Step 1: Write failing test**

(Test asserts that `get_messages` collects from both layers and `handles_for_select` returns the union.)

```perl
subtest combined_handles => sub {
    my $sp = ipcm_spawn(protocol => 'MessageFiles', service_protocol => 'ServiceUnix', guard => 0);
    my $a = IPC::Manager::ipcm_connect('a', $sp->info, auth_key => $sp->auth_key);

    ok($a->have_handles_for_select, 'composite has handles_for_select');
    my @h = $a->handles_for_select;
    ok(scalar @h, 'has at least one handle (main)');

    $a->disconnect;
};
```

- [ ] **Step 2: FAIL** — composite has no `get_messages` / `handles_for_select` yet.

- [ ] **Step 3: Implement**

```perl
sub have_handles_for_select { 1 }

sub handles_for_select {
    my $self = shift;
    my @h;
    push @h, $self->{+MAIN}->handles_for_select
        if $self->{+MAIN}->have_handles_for_select;
    push @h, $self->{+SERVICE}->handles_for_select;
    return @h;
}

sub get_messages {
    my $self = shift;
    my @out;

    push @out, $self->{+MAIN}->get_messages;

    # Drive the service-side I/O.
    $self->{+SERVICE}->accept_pending;
    $self->{+SERVICE}->advance_handshakes;
    $self->{+SERVICE}->advance_dials;
    $self->{+SERVICE}->drain_all_streams;
    $self->{+SERVICE}->flush_outboxes;

    push @out, $self->{+SERVICE}->take_all_stream_messages;

    return $self->sort_messages(@out);
}

sub take_new_connections      { $_[0]->{+SERVICE}->take_new_connections }
sub take_lost_connections     { $_[0]->{+SERVICE}->take_lost_connections }
sub take_rejected_connections { $_[0]->{+SERVICE}->take_rejected_connections }
```

- [ ] **Step 4: PASS**

- [ ] **Step 5: Commit**

```bash
git add lib/IPC/Manager/Client/Composite.pm t/unit/Client-Composite.t
git commit -m "Client::Composite: get_messages combines layers; handles_for_select union"
```

---

### Task 21: Composite `start_service_listener`

**Files:**
- Modify: `lib/IPC/Manager/Client/Composite.pm`
- Test: `t/unit/Client-Composite.t`

- [ ] **Step 1: Write failing test**

```perl
subtest start_service_listener => sub {
    my $sp = ipcm_spawn(protocol => 'MessageFiles', service_protocol => 'ServiceUnix', guard => 0);
    my $svc = IPC::Manager::ipcm_connect('svcA', $sp->info, auth_key => $sp->auth_key);

    $svc->start_service_listener;
    my $ep = $sp->connect('peek')->peer_service_endpoint('svcA');
    ok($ep, 'endpoint published');
    is($ep->{type}, 'unix');

    $svc->disconnect;
};
```

- [ ] **Step 2: FAIL**

- [ ] **Step 3: Implement**

```perl
sub start_service_listener {
    my $self = shift;
    $self->{+SERVICE}->start_listener;
    $self->{+MAIN}->publish_service_endpoint(
        $self->{+ID},
        $self->{+SERVICE}->listen_endpoint,
    );
}
```

- [ ] **Step 4: PASS**

- [ ] **Step 5: Commit**

```bash
git add lib/IPC/Manager/Client/Composite.pm t/unit/Client-Composite.t
git commit -m "Client::Composite: start_service_listener publishes endpoint"
```

---

## Phase F — Service loop integration

### Task 22: `Role::Service::watch` expansion

**Files:**
- Modify: `lib/IPC/Manager/Role/Service.pm`
- Test: `t/unit/Role-Service.t`

- [ ] **Step 1: Write failing test**

A unit test that gives `watch()` a mock client whose `get_messages` returns a fixed list, and a mock service that records `accept_pending` / `advance_handshakes` / `drain_all_streams` calls. Verify activity hash includes `new_connections` etc. when the mock pushes to the accumulators.

(Use a fake class with `Object::HashBase` and the methods the role expects. Pattern follows existing tests in `t/unit/Role-Service.t`.)

```perl
subtest watch_new_connections => sub {
    my $fake = FakeComposite->new(
        messages_to_return    => [],
        new_connections_pop   => ['cliA'],
        lost_connections_pop  => [],
        rejected_pop          => [],
    );
    my $svc = build_service_using($fake);

    my $activity = $svc->watch({});
    is_deeply($activity->{new_connections}, ['cliA']);
};
```

(Define `FakeComposite` inline in the test file with the small interface the role needs.)

- [ ] **Step 2: FAIL**

- [ ] **Step 3: Modify `Role::Service::watch`**

In `lib/IPC/Manager/Role/Service.pm`, replace the `if ($select)` block in `watch` (around line 395):

```perl
        my @messages;
        if ($select) {
            if ($select->can_read($cycle)) {
                @messages = $client->get_messages;
                $client->reset_handles_for_peer_change if $client->have_handles_for_peer_change;
            }
        }
        else {
            @messages = $client->get_messages;
        }

        # Service-socket-driven activity. The composite is responsible
        # for funnelling these through get_messages already, but we
        # still need to harvest the per-cycle accumulators if the
        # client supports them.
        if ($client->can('take_new_connections')) {
            my $nc = $client->take_new_connections;
            $activity{new_connections} = $nc if $nc && @$nc;
        }
        if ($client->can('take_lost_connections')) {
            my $lc = $client->take_lost_connections;
            $activity{lost_connections} = $lc if $lc && @$lc;
        }
        if ($client->can('take_rejected_connections')) {
            my $rc = $client->take_rejected_connections;
            $activity{rejected_connections} = $rc if $rc && @$rc;
        }
```

- [ ] **Step 4: PASS**

- [ ] **Step 5: Commit**

```bash
git add lib/IPC/Manager/Role/Service.pm t/unit/Role-Service.t
git commit -m "Role::Service: harvest connection accumulators in watch()"
```

---

### Task 23: `Role::Service::run` dispatches new keys + defaults

**Files:**
- Modify: `lib/IPC/Manager/Role/Service.pm`
- Test: `t/unit/Role-Service.t`

- [ ] **Step 1: Write failing test**

Test that `run_on_new_connection`, `run_on_lost_connection`, and `run_on_rejected_connection` are invoked by the run loop when activity contains those keys.

- [ ] **Step 2: FAIL**

- [ ] **Step 3: Implement**

In `lib/IPC/Manager/Role/Service.pm`, add to the no-op default block:

```perl
sub run_on_new_connection      { }
sub run_on_lost_connection     { }
sub run_on_rejected_connection {
    my ($self, $rec) = @_;
    $self->debug("rejected connection: " .
                 ($rec->{reason} // '?') . " from " .
                 ($rec->{claimed_from} // '?') . "\n");
}
```

Add `_run_on_*` wrappers parallel to the existing ones:

```perl
sub _run_on_new_connection      { my ($self, @args) = @_; $self->try(sub { $self->run_on_new_connection(@args)      }) }
sub _run_on_lost_connection     { my ($self, @args) = @_; $self->try(sub { $self->run_on_lost_connection(@args)     }) }
sub _run_on_rejected_connection { my ($self, @args) = @_; $self->try(sub { $self->run_on_rejected_connection(@args) }) }
```

In `run()`, add dispatch after `pid_watch` but before `interval`:

```perl
        if (my $nc = delete $activity->{new_connections}) {
            $self->_run_on_new_connection($_) for @$nc;
        }

        if (my $lc = delete $activity->{lost_connections}) {
            $self->_run_on_lost_connection($_) for @$lc;
        }

        if (my $rc = delete $activity->{rejected_connections}) {
            $self->_run_on_rejected_connection($_) for @$rc;
        }
```

- [ ] **Step 4: PASS**

- [ ] **Step 5: Commit**

```bash
git add lib/IPC/Manager/Role/Service.pm t/unit/Role-Service.t
git commit -m "Role::Service: dispatch on_(new|lost|rejected)_connection in run()"
```

---

### Task 24: `IPC::Manager::Service` `@ACTIONS` extension

**Files:**
- Modify: `lib/IPC/Manager/Service.pm`
- Test: `t/unit/Service.t`

- [ ] **Step 1: Write failing test**

```perl
subtest connection_actions => sub {
    my $svc = IPC::Manager::Service->new(
        name           => 'svc',
        ipcm_info      => 'unused',
        handle_request => sub { },
        on_new_connection      => sub { },
        on_lost_connection     => sub { },
        on_rejected_connection => sub { },
    );

    can_ok($svc, qw/run_on_new_connection run_on_lost_connection run_on_rejected_connection
                    push_on_new_connection clear_on_new_connection/);
};
```

- [ ] **Step 2: FAIL**

- [ ] **Step 3: Add to @ACTIONS**

In `lib/IPC/Manager/Service.pm` `@ACTIONS` BEGIN block:

```perl
    @ACTIONS = qw{
        on_all
        on_cleanup
        on_general_message
        on_interval
        on_new_connection
        on_lost_connection
        on_rejected_connection
        on_peer_delta
        on_pid
        on_start
        on_unhandled
        should_end
    };
```

(The codegen at the bottom of `Service.pm` produces the `push_*` / `clear_*` / `run_*` accessors automatically.)

- [ ] **Step 4: PASS**

- [ ] **Step 5: Commit**

```bash
git add lib/IPC/Manager/Service.pm t/unit/Service.t
git commit -m "IPC::Manager::Service: add on_(new|lost|rejected)_connection actions"
```

---

### Task 25: `ipcm_service` triggers `start_service_listener`

**Files:**
- Modify: `lib/IPC/Manager/Service/State.pm`
- Test: integration test in next phase

- [ ] **Step 1: Write failing test**

(Defer to integration tests in Phase G — this glue is too entangled with forks for a meaningful unit test. Add a placeholder test stub now that asserts presence of the method:)

In `t/unit/Service-Handle.t`, append:

```perl
subtest composite_listener_invocation => sub {
    can_ok('IPC::Manager::Service::State', '_maybe_start_service_listener');
};
```

- [ ] **Step 2: FAIL**

- [ ] **Step 3: Implement**

In `lib/IPC/Manager/Service/State.pm`, after `$new_inst->post_fork_hook();` in the child branch:

```perl
    _maybe_start_service_listener($new_inst);
```

Add helper:

```perl
sub _maybe_start_service_listener {
    my ($inst) = @_;
    my $client = $inst->client;
    return unless ref($client) eq 'IPC::Manager::Client::Composite';
    eval { $client->start_service_listener; 1 } or do {
        warn "start_service_listener failed: $@";
        die $@;
    };
}
```

- [ ] **Step 4: PASS**

- [ ] **Step 5: Commit**

```bash
git add lib/IPC/Manager/Service/State.pm t/unit/Service-Handle.t
git commit -m "Service::State: start composite service listener post-fork"
```

---

## Phase G — Integration tests

### Task 26: `IPC::Manager::Test` extensions

**Files:**
- Modify: `lib/IPC/Manager/Test.pm`
- Tests: invoked via per-protocol `t/ServiceUnix/test_*.t` etc.

Add new test methods (each will be one subtest in any service-protocol suite):

- [ ] **Step 1: Add new test methods (each is a method in `IPC::Manager::Test`)**

For each new method below, add it as a sub in `IPC::Manager::Test`. Pattern follows existing methods like `test_simple_service`. Read 2-3 existing methods for boilerplate before writing these.

```perl
sub test_service_socket_basic {
    my $class = shift;
    # Spawn with main + service protocol, start a service, send request, get response.
}

sub test_multi_service_concurrent {
    my $class = shift;
    # One client, three services, interleaved requests, verify per-stream
    # ordering and that no stream blocks another.
}

sub test_multi_client_to_service {
    my $class = shift;
    # One service, three clients, each sends a request, verify each gets
    # a correct response.
}

sub test_service_to_service {
    my $class = shift;
    # Two services A and B; A sends a request to B and receives response.
}

sub test_dup_race {
    my $class = shift;
    # Two services dial each other "simultaneously" via a sync barrier;
    # verify lower-uuid stream wins and on_new_connection fires exactly
    # once on each side.
}

sub test_rejected_connections {
    my $class = shift;
    # A peer connects with the wrong auth key; service raises
    # on_rejected_connection with reason=bad_key; that peer is NOT
    # listed in peers().
}

sub test_lost_connection_then_redial {
    my $class = shift;
    # Force-close a stream; verify on_lost_connection fires; verify
    # next send_message redials successfully.
}
```

Each method body must be a complete test. Use existing `test_simple_service` as your template — mirror its structure, replacing the body of the `on_all` callback with the scenario-specific assertions.

- [ ] **Step 2: Each method has its own commit and runs green**

Run after each method is added:

```
prove -Ilib -j16 t/ServiceUnix/
```

- [ ] **Step 3: Commits (one per method)**

```bash
git add lib/IPC/Manager/Test.pm
git commit -m "Test: add test_<method>"
```

(Repeat for each method. Each commit is small and focused.)

---

### Task 27: `t/ServiceUnix/test_*.t` per-subtest entry points

**Files:**
- Create: one .t per method in Task 26 under `t/ServiceUnix/`
- Pattern: copy `t/UnixSocket/test_simple_service.t` and substitute the protocol + test name

- [ ] **Step 1: Create the .t files**

For each test method added in Task 26, create `t/ServiceUnix/<method>.t`:

```perl
use Test2::V1 -ipP;
use Test2::IPC;
use Test2::Require::Module 'IO::Socket::UNIX' => '1.55';
use lib 't/lib';
use IPC::Manager::Test;
IPC::Manager::Test->run_one(
    protocol         => 'MessageFiles',
    service_protocol => 'ServiceUnix',
    test             => 'test_<method_name>',
);

done_testing;
```

`run_one` will need to accept `service_protocol` and propagate it to `ipcm_default_protocol` style storage. Add to `IPC::Manager::Test` a small change:

```perl
sub run_one {
    my $class  = shift;
    my %params = @_;
    ...
    if (my $sp = $params{service_protocol}) {
        $class->_default_service_protocol($sp);
    }
    ...
}

{
    my $sp;
    sub _default_service_protocol {
        my $class = shift;
        $sp = $_[0] if @_;
        return $sp;
    }
}
```

In each `test_*` method, when calling `ipcm_spawn`, include `service_protocol => $class->_default_service_protocol`.

- [ ] **Step 2: Run**

```
prove -Ilib -j16 t/ServiceUnix/
```

- [ ] **Step 3: Commit**

```bash
git add t/ServiceUnix/*.t lib/IPC/Manager/Test.pm
git commit -m "Test: ServiceUnix per-subtest entry points + service_protocol plumbing"
```

---

### Task 28: `t/ServiceIP/test_*.t` per-subtest entry points

**Files:**
- Create: one .t per method under `t/ServiceIP/`

- [ ] **Step 1: Create files**

Same pattern as Task 27, but with:

```perl
use Test2::Require::Module 'IO::Socket::INET';
...
IPC::Manager::Test->run_one(
    protocol         => 'MessageFiles',
    service_protocol => 'ServiceIP',
    test             => 'test_<method_name>',
);
```

- [ ] **Step 2: Run**

```
prove -Ilib -j16 t/ServiceIP/
```

- [ ] **Step 3: Commit**

```bash
git add t/ServiceIP/*.t
git commit -m "Test: ServiceIP per-subtest entry points"
```

---

### Task 29: Sanity-check parity test

**Files:**
- Test: `t/ServiceUnix/test_sanity_check.t`, `t/ServiceIP/test_sanity_check.t`
- (Possibly modify: `lib/IPC/Manager/Spawn.pm` if `sanity_delta` needs adjustments — verify with the test first)

- [ ] **Step 1: Write failing test**

```perl
sub test_sanity_check {
    my $class = shift;
    my $sp = ipcm_spawn(
        protocol         => 'MessageFiles',
        service_protocol => $class->_default_service_protocol,
    );

    my $svc_handle = ipcm_service('svcA', sub {});
    my $client = ipcm_connect('cliA', $sp->info, auth_key => $sp->auth_key);

    $client->send_message('svcA', { ping => 1 });
    # ... wait for delivery, etc., per existing pattern ...

    is($sp->sanity_delta, undef, 'no sent/received mismatch');

    $client->disconnect;
    $sp->shutdown;
}
```

- [ ] **Step 2: FAIL or PASS**

If the test fails, audit `Base::ServiceSocket`'s stats updates: `send_stream_message` and `_pull_complete_messages` already increment `STATS->{sent}` / `STATS->{read}`. Stats persist via main driver's `write_stats` because the composite delegates `read_stats` / `write_stats` to main, and the composite shares its `STATS` field with main on commits. Verify and fix as needed.

If a fix is needed: route stats through the main driver explicitly so `all_stats` includes stream traffic.

- [ ] **Step 3: Land**

- [ ] **Step 4: PASS**

- [ ] **Step 5: Commit**

```bash
git add t/ServiceUnix/test_sanity_check.t t/ServiceIP/test_sanity_check.t \
        lib/IPC/Manager/Test.pm
git commit -m "Test: sanity_check accounts for stream-delivered messages"
```

---

### Task 30: `exec` service test (auth-key inheritance)

**Files:**
- Modify: `lib/IPC/Manager/Test.pm`
- Test: `t/ServiceUnix/test_exec_service_auth.t`

- [ ] **Step 1: Add test method**

```perl
sub test_exec_service_auth {
    my $class = shift;
    my $sp = ipcm_spawn(
        protocol         => 'MessageFiles',
        service_protocol => $class->_default_service_protocol,
    );

    my $svc = ipcm_service('svcA', { exec => { cmd => [] } }, sub { ... });

    my $cli = ipcm_connect('cliA', $sp->info, auth_key => $sp->auth_key);
    $cli->send_message('svcA', { ping => 1 });
    # ... await response via standard pattern ...
    pass('exec service accepted authenticated connection');
}
```

- [ ] **Step 2-5: TDD as before, commit**

---

## Phase H — Companion + docs

### Task 31: SharedMem companion stubs

**Files:**
- Modify: `../IPC-Manager-Client-SharedMem/lib/IPC/Manager/Client/SharedMem.pm` (path may vary; verify with `ls ../IPC-Manager-Client-SharedMem/lib/IPC/Manager/Client/`)
- Test: companion repo's existing test suite must still pass

- [ ] **Step 1: Inspect companion**

```bash
ls -la ../IPC-Manager-Client-SharedMem/lib/IPC/Manager/Client/
git -C ../IPC-Manager-Client-SharedMem log --oneline -5
```

- [ ] **Step 2: Inherit defaults**

`SharedMem` extends `IPC::Manager::Client` (or a base class that does). The new methods `peer_service_endpoint`, `publish_service_endpoint`, `retract_service_endpoint` have safe default no-op implementations on the base; SharedMem will inherit them automatically. Verify with the companion's test suite.

- [ ] **Step 3: Run companion tests**

```bash
cd ../IPC-Manager-Client-SharedMem
prove -Ilib -j16 -r t/
```

- [ ] **Step 4: If failing, add explicit stubs**

If a SharedMem test breaks because of missing methods, add to `SharedMem.pm`:

```perl
sub peer_service_endpoint   { undef }
sub publish_service_endpoint { }
sub retract_service_endpoint { }
```

- [ ] **Step 5: Commit (in the companion repo)**

```bash
cd ../IPC-Manager-Client-SharedMem
git add lib/IPC/Manager/Client/SharedMem.pm
git commit -m "SharedMem: stub service-endpoint methods for IPC-Manager 0.000035 compat"
```

---

### Task 32: Documentation / POD

**Files:**
- Modify: `lib/IPC/Manager.pm` (add composite mode section)
- Modify: each new `.pm` file's `__END__` POD section

- [ ] **Step 1: Update `lib/IPC/Manager.pm` POD**

Add a "Service Socket Transports" section under "Client Protocols" that explains:
- `service_protocol` option to `ipcm_spawn`
- `auth_key` option to `ipcm_connect`
- Composite return value
- Reference to `IPC::Manager::Client::Composite` for details

(See spec doc for the technical wording.)

- [ ] **Step 2: Add POD to each new `.pm`**

For `Composite.pm`, `ServiceUnix.pm`, `ServiceIP.pm`, `Base/ServiceSocket.pm`: write a NAME / DESCRIPTION / SYNOPSIS / METHODS section following the pattern of `lib/IPC/Manager/Client/UnixSocket.pm`.

- [ ] **Step 3: Run POD checks (if any)**

```bash
prove -Ilib t/release-pod-coverage.t 2>/dev/null \
    || perl -c lib/IPC/Manager/Client/Composite.pm
```

- [ ] **Step 4: Commit**

```bash
git add lib/IPC/Manager.pm lib/IPC/Manager/Client/Composite.pm \
        lib/IPC/Manager/Client/ServiceUnix.pm \
        lib/IPC/Manager/Client/ServiceIP.pm \
        lib/IPC/Manager/Base/ServiceSocket.pm
git commit -m "Docs: POD for Composite, ServiceUnix, ServiceIP, Base::ServiceSocket"
```

---

## Final Validation

- [ ] Run the full test suite: `prove -Ilib -j16 -r t/` (5-minute timeout)
- [ ] Run companion tests: `cd ../IPC-Manager-Client-SharedMem && prove -Ilib -j16 -r t/`
- [ ] Verify `git log streaming_deadlock..HEAD` shows the planned commits in order
- [ ] If `streaming_deadlock` has advanced, rebase with `git rebase streaming_deadlock` and re-verify per the spec's "Parent-branch volatility" section

---

## Out-of-scope (deferred, do NOT implement here)

- Idle-timeout-based stream eviction
- TLS / encrypted transport
- Cross-host reachability beyond loopback
- Replacing connectionless `UnixSocket` driver
- A `RemoteUnix` / `RemoteIP` variant for non-localhost access

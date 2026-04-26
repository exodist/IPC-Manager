use Test2::V0;
use Test2::Require::Module 'IO::Socket::UNIX' => '1.55';

use File::Temp qw/tempdir/;
use File::Spec;
use Time::HiRes qw/time sleep/;

use IPC::Manager::Client::ConnectionUnix;
use IPC::Manager::Serializer::JSON;

my $CLASS      = 'IPC::Manager::Client::ConnectionUnix';
my $SERIALIZER = 'IPC::Manager::Serializer::JSON';

# Helper: drain messages until $count arrive at $con or timeout.
sub drain_until {
    my ($con, $count, $timeout) = @_;
    $timeout //= 5;
    my @msgs;
    my $deadline = time + $timeout;
    while (@msgs < $count && time < $deadline) {
        push @msgs => $con->get_messages;
        last if @msgs >= $count;
        sleep 0.02;
    }
    return @msgs;
}

subtest 'viable / path_type / suspend' => sub {
    ok($CLASS->viable, 'viable');
    is($CLASS->path_type, 'UNIX Socket or marker file', 'path_type');
    ok(!$CLASS->suspend_supported, 'suspend not supported');
};

subtest 'connect listener and disconnect' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $con = $CLASS->new(serializer => $SERIALIZER, route => $dir, id => 'cd1');
    isa_ok($con, [$CLASS], 'right class');
    is($con->id, 'cd1', 'id');
    ok($con->listen, 'listen default 1');
    ok(-S File::Spec->catfile($dir, 'cd1'), 'listen socket on disk');
    $con->disconnect;
    ok(!-e File::Spec->catfile($dir, 'cd1'), 'cleaned up');
};

subtest 'non-listener marker file' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $con = $CLASS->new(serializer => $SERIALIZER, route => $dir, id => 'nl1', listen => 0);
    ok(-f File::Spec->catfile($dir, 'nl1'), 'marker file exists');
    ok(!-S File::Spec->catfile($dir, 'nl1'), 'marker file is not a socket');
    ok(!$con->listen, 'listen 0');
    $con->disconnect;
};

subtest 'send and receive between two listeners' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $con1 = $CLASS->new(serializer => $SERIALIZER, route => $dir, id => 'a');
    my $con2 = $CLASS->new(serializer => $SERIALIZER, route => $dir, id => 'b');

    ok($con1->peer_is_listener('b'), 'b is listener');
    ok($con2->peer_is_listener('a'), 'a is listener');

    $con1->send_message(b => {hello => 'world'});

    my @msgs = drain_until($con2, 1);
    is(scalar @msgs, 1, 'one message');
    is($msgs[0]->from,    'a', 'from');
    is($msgs[0]->to,      'b', 'to');
    is($msgs[0]->content, {hello => 'world'}, 'content');

    ok($con1->has_connection('b'), 'con1 cached connection to b');

    $con1->disconnect;
    $con2->disconnect;
};

subtest 'non-listener initiates, listener replies on same fd' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $listener  = $CLASS->new(serializer => $SERIALIZER, route => $dir, id => 'srv');
    my $initiator = $CLASS->new(serializer => $SERIALIZER, route => $dir, id => 'cli', listen => 0);

    ok( $initiator->peer_is_listener('srv'), 'srv is listener');
    ok(!$listener->peer_is_listener('cli'),  'cli is not listener');

    $initiator->send_message(srv => 'ping');

    my @rx1 = drain_until($listener, 1);
    is(scalar @rx1, 1, 'listener got message from non-listener');
    is($rx1[0]->content, 'ping', 'content');

    ok($listener->has_connection('cli'), 'listener cached cli');

    # Listener replies — must reuse the inbound connection.
    $listener->send_message(cli => 'pong');

    my @rx2 = drain_until($initiator, 1);
    is(scalar @rx2, 1, 'initiator got reply');
    is($rx2[0]->content, 'pong', 'reply content');

    $initiator->disconnect;
    $listener->disconnect;
};

subtest 'send to non-listener with no cached connection croaks' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $a = $CLASS->new(serializer => $SERIALIZER, route => $dir, id => 'a');
    my $b = $CLASS->new(serializer => $SERIALIZER, route => $dir, id => 'b', listen => 0);

    like(
        dies { $a->send_message(b => 'nope') },
        qr/no active connection to 'b' and peer is not listening/,
        'cannot send to non-listener with no connection',
    );

    $a->disconnect;
    $b->disconnect;
};

subtest 'multiple messages ordering' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $a = $CLASS->new(serializer => $SERIALIZER, route => $dir, id => 'a');
    my $b = $CLASS->new(serializer => $SERIALIZER, route => $dir, id => 'b');

    $a->send_message(b => 'first');
    $a->send_message(b => 'second');
    $a->send_message(b => 'third');

    my @msgs = drain_until($b, 3);
    is(scalar @msgs, 3, 'three messages');
    is([map { $_->content } @msgs], ['first','second','third'], 'in order');

    $a->disconnect;
    $b->disconnect;
};

subtest 'broadcast' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $con1 = $CLASS->new(serializer => $SERIALIZER, route => $dir, id => 'bc1');
    my $con2 = $CLASS->new(serializer => $SERIALIZER, route => $dir, id => 'bc2');
    my $con3 = $CLASS->new(serializer => $SERIALIZER, route => $dir, id => 'bc3');

    my $res = $con1->broadcast({mass => 'msg'});

    is($res->{bc2}->{sent}, 1, 'sent to bc2');
    is($res->{bc3}->{sent}, 1, 'sent to bc3');

    my @m2 = drain_until($con2, 1);
    my @m3 = drain_until($con3, 1);
    is(scalar @m2, 1, 'bc2 got broadcast');
    is(scalar @m3, 1, 'bc3 got broadcast');
    is($m2[0]->content, {mass => 'msg'}, 'content');

    $con1->disconnect;
    $con2->disconnect;
    $con3->disconnect;
};

subtest 'have_handles_for_select' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $con = $CLASS->new(serializer => $SERIALIZER, route => $dir, id => 'sel');
    ok($con->have_handles_for_select, 'has select handles');
    my @h = $con->handles_for_select;
    ok(scalar @h, 'returned handles');
    $con->disconnect;
};

subtest 'role API' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $a = $CLASS->new(serializer => $SERIALIZER, route => $dir, id => 'a');
    my $b = $CLASS->new(serializer => $SERIALIZER, route => $dir, id => 'b');

    ok(!$a->has_connection('b'), 'no connection initially');

    $a->send_message(b => 'hi');
    drain_until($b, 1);
    drain_until($a, 0, 0.2);    # let listener side accept

    ok($a->has_connection('b'), 'a has connection to b after send');
    ok($b->has_connection('a'), 'b has connection to a after accept');
    is([$a->connections], ['b'], 'a->connections');
    is([$b->connections], ['a'], 'b->connections');

    cmp_ok($a->last_activity('b'), '>', 0, 'a last_activity to b');

    is($a->disconnect_connection('b'), 1, 'disconnect_connection');
    ok(!$a->has_connection('b'), 'gone');

    # close_idle_connections: re-establish, then age the timestamp.
    $a->send_message(b => 'again');
    drain_until($b, 1);
    ok($a->has_connection('b'), 'reconnected');
    $a->_connections->{b}->{last_active} = time - 1000;
    my $closed = $a->close_idle_connections(10);
    is($closed, 1, 'closed 1 idle');
    ok(!$a->has_connection('b'), 'gone after idle close');

    $a->disconnect;
    $b->disconnect;
};

subtest 'reconnect once on dead fd' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $a = $CLASS->new(serializer => $SERIALIZER, route => $dir, id => 'a');
    my $b = $CLASS->new(serializer => $SERIALIZER, route => $dir, id => 'b');

    $a->send_message(b => 'first');
    drain_until($b, 1);
    ok($a->has_connection('b'), 'connection cached');

    # Brutally close the fd from a's side without removing the cache entry,
    # forcing the next send to detect the dead fd and reconnect.
    my $fh = $a->_connections->{b}->{fh};
    close($fh);

    my $ok = eval { $a->send_message(b => 'after-reset'); 1 };
    ok($ok, 'second send succeeded via reconnect') or diag $@;

    my @msgs = drain_until($b, 1);
    is(scalar @msgs, 1, 'message arrived after reconnect');
    is($msgs[0]->content, 'after-reset', 'content matches');

    $a->disconnect;
    $b->disconnect;
};

subtest 'stats tracking' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $a = $CLASS->new(serializer => $SERIALIZER, route => $dir, id => 'sa');
    my $b = $CLASS->new(serializer => $SERIALIZER, route => $dir, id => 'sb');

    $a->send_message(sb => 'x');
    $a->send_message(sb => 'y');
    drain_until($b, 2);

    is($a->stats->{sent}->{sb}, 2, 'sent count');
    is($b->stats->{read}->{sa}, 2, 'read count');

    $a->disconnect;
    $b->disconnect;
};

subtest 'listening_peers and peer_is_listener' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $a = $CLASS->new(serializer => $SERIALIZER, route => $dir, id => 'a');
    my $b = $CLASS->new(serializer => $SERIALIZER, route => $dir, id => 'b');
    my $c = $CLASS->new(serializer => $SERIALIZER, route => $dir, id => 'c', listen => 0);

    is([sort $a->peers], ['b','c'], 'peers includes both');
    is([sort $a->listening_peers], ['b'], 'listening_peers excludes c');
    ok( $a->peer_is_listener('b'), 'b listener');
    ok(!$a->peer_is_listener('c'), 'c not listener');

    $a->disconnect;
    $b->disconnect;
    $c->disconnect;
};

done_testing;

use Test2::V1 -ipP;
use Test2::IPC;
use Time::HiRes qw/sleep/;
use Carp::Always;
use Data::Dumper;
use POSIX;

use IPC::Manager;

my $man = IPC::Manager->new(
    protocol       => $main::PROTOCOL,
    handle_message => sub {
        my ($con, $msg) = @_;

        if ($msg->content->{ping}) {
            $con->send_message($msg->from, {pong => 1});
        }
        else {
            die "Unexpected message: " . Dumper($msg);
        }
    },
);

isa_ok($man, ['IPC::Manager'], "Created an instance");

my $info = eval { $man->spawn() } or do {
    print STDERR $@;
    POSIX::_exit(255);
};
ok($info, "Got connection info ($info)");

my $con1 = $man->connect('con1');
isa_ok($con1, ['IPC::Manager::Client'], "Got a connection");

my $con2 = IPC::Manager::Client->connect($man->connect_string, 'con2');
isa_ok($con2, ['IPC::Manager::Client'], "Got a connection again");

$con1->send_message(con2 => {hi   => 'there'});
$con2->send_message(con1 => {ahoy => 'matey'});

like(
    [$con1->get_messages],
    [{
        id      => T(),
        stamp   => T(),
        from    => 'con2',
        to      => 'con1',
        content => {ahoy => 'matey'},
    }],
    "Got message sent from con2 to con1"
);

like(
    [$con2->get_messages],
    [{
        id      => T(),
        stamp   => T(),
        from    => 'con1',
        to      => 'con2',
        content => {hi => 'there'},
    }],
    "Got message sent from con1 to con2"
);

like([$con1->get_messages], [], "No messages");
like([$con2->get_messages], [], "No messages");

$con1->send_message('manager' => {ping => 1});

sleep 0.02 until $con1->ready_messages;

like(
    [$con1->get_messages],
    [{
        id      => T(),
        stamp   => T(),
        from    => 'manager',
        to      => 'con1',
        content => {pong => 1},
    }],
    "Got message sent from con1 to manager and a response received"
);

my $pid = fork;

if ($pid) {
    note "Parent $$, child $pid\n";
    note "[$$] Waiting for child process...\n";
    sleep 0.2 until $con1->client_exists('con3');
    note "[$$] Terminating...\n";

    $con1 = undef;
    $con2 = undef;

    $man = $man->stop;
    note "[$$] Terminted...\n";
    note "[$$] Waiting for child process to exit...\n";
    waitpid($pid, 0);
    note "[$$] Child has exited ($?)\n";
    ok(!$?, "Child exited cleanly");
}
else {
    my $con3 = $man->connect('con3');
    $man = undef;

    note "[$$] Child is waiting for a message.\n";
    my @msgs;
    for (1 .. 200) {
        @msgs = $con3->get_messages;
        last if @msgs;
        sleep 0.02;
    }

    note "[$$] Child got a message.\n";

    like(
        \@msgs,
        [{
            id        => T(),
            stamp     => T(),
            broadcast => T(),
            from      => 'manager',
            content   => {terminate => 1},
        }],
        "Got termination message"
    );

    note "[$$] Child disconnecting\n";
    $con3->disconnect;

    note "[$$] Child exiting\n";
    eval { exit(0) };
    note "[$$] Forcing child exit\n";
    POSIX::_exit(255);
}

ok(!-e $info, "Info does not exist on the filesystem");

done_testing;

1;

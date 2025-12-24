use Test2::V1 -ipP;
use Test2::IPC;
use Time::HiRes qw/sleep/;
use Carp::Always;
use POSIX;

use IPC::Manager;

my @msgs;
my $man = IPC::Manager->new(
    protocol       => $main::PROTOCOL,
    handle_message => sub { push @msgs => pop },
);

isa_ok($man, ['IPC::Manager'], "Created an instance");

my $info = $man->start;
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

$con1->send_message('manager' => {blah => 1});
ok(!@msgs, "No manager messages yet");
$man->iterate;
like(
    \@msgs,
    [{
        id      => T(),
        stamp   => T(),
        from    => 'con1',
        to      => 'manager',
        content => {blah => 1},
    }],
    "Got message sent from con1 to con2"
);

my $pid = fork;

if ($pid) {
    diag "Parent $$, child $pid\n";
    diag "[$$] Waiting for child process...\n";
    sleep 0.2 until $man->client_exists('con3');
    diag "[$$] Terminating...\n";
    $man = undef;
    diag "[$$] Terminted...\n";
    diag "[$$] Waiting for child process to exit...\n";
    waitpid($pid, 0);
    diag "[$$] Child has exited ($?)\n";
    ok(!$?, "Child exited cleanly");
}
else {
    my $con3 = $man->connect('con3');
    $man = undef;

    diag "[$$] Child is waiting for a message.\n";
    my @msgs;
    for (1 .. 200) {
        @msgs = $con3->get_messages;
        last if @msgs;
        sleep 0.02;
    }

    diag "[$$] Child got a message.\n";

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

    diag "[$$] Child disconnecting\n";
    $con3->disconnect;

    diag "[$$] Child exiting\n";
    eval { exit(0) };
    diag "[$$] Forcing child exit\n";
    POSIX::_exit(255);
}

ok(!-e $info, "Info does not exist on the filesystem");

done_testing;

1;

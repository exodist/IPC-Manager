use Test2::V1 -ipP;
use Test2::IPC;
use Time::HiRes qw/sleep/;
use Carp::Always;
use Data::Dumper;
use POSIX;

use IPC::Manager qw/ipcm_connect ipcm_spawn/;

note("Using $main::PROTOCOL");

my $guard = ipcm_spawn(protocol => $main::PROTOCOL);
my $info = "$guard";

isa_ok($guard, ['IPC::Manager::Spawn'], "Got a spawn object");
is($info, $guard->connect_string, "Stringifies");
like($info, qr/^IPC::Manager::Client::\w+\|/, "String looks correct");
note("Info: $info");

my $con1 = ipcm_connect('con1' => $info);
my $con2 = ipcm_connect('con2' => $info);
note("Con: $con1");

isa_ok($con1, ['IPC::Manager::Client'], "Got a connection (con1)");
isa_ok($con2, ['IPC::Manager::Client'], "Got a connection (con2)");

like([$con1->get_messages], [], "No messages");
like([$con2->get_messages], [], "No messages");

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

$guard = undef;
ok(!-e $info, "Info does not exist on the filesystem");

done_testing;

1;

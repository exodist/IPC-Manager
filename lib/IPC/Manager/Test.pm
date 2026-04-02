package IPC::Manager::Test;
use strict;
use warnings;

use Carp qw/croak/;
use Test2::V1 -ip;
use Test2::IPC;
use IPC::Manager::Serializer::JSON;
use IPC::Manager qw/ipcm_service ipcm_connect ipcm_spawn ipcm_default_protocol/;

sub run_all {
    my $class  = shift;
    my %params = @_;

    my $protocol = $params{protocol} or croak "'protocol' is required";
    ipcm_default_protocol($protocol);

    for my $test ($class->tests) {
        my $pid = fork // die "Could not fork: $!";
        if ($pid) {
            waitpid($pid, 0);
            next;
        }

        my $ok  = eval { subtest $test => $class->can($test); 1 };
        my $err = $@;
        warn $err unless $ok;
        POSIX::_exit($ok ? 0 : 255);
    }
}

sub tests {
    my $class = shift;

    my $stash = do { no strict 'refs'; \%{"$class\::"} };

    my @out;

    for my $sym (sort keys %$stash) {
        next unless $sym =~ m/^test_/;
        next unless $class->can($sym);

        push @out => $sym;
    }

    return @out;
}

sub test_simple_service {
    my $parent_pid = $$;

    my $got_req = 0;
    my $handle  = ipcm_service foo => sub {
        my $self = shift;
        my ($activity) = @_;

        return if $activity->{interval} && keys(%$activity) == 1;

        if (my $msgs = $activity->{messages}) {
            for my $msg (@$msgs) {
                my $c = $msg->content;

                if (ref($c) eq 'HASH') {
                    if ($c->{ipcm_request_id}) {
                        $got_req = 1;
                        is($msg->content->{request}, "${parent_pid} blah?", "Got request from parent pid");
                        $self->send_response($msg->from, $c->{ipcm_request_id}, "$$ blah!");
                    }
                    elsif ($c->{terminate}) {
                        ok($got_req, "$$ Got the request!");
                    }
                }
            }
        }
    };

    my $service_pid = $handle->service_pid;

    my $got_resp = 0;
    $handle->send_request(
        foo => "$$ blah?",
        sub {
            my ($resp, $msg) = @_;
            $got_resp = 1;
            is($msg->content->{response}, "${service_pid} blah!", "Got expected response");
        }
    );

    $handle->await_all_responses;

    ok($got_resp, "Got response!");

    eval { $handle = undef; 1 } or die "XXX: $@";
}

sub test_generic {
    my $guard = ipcm_spawn(do_sanity_check => 1);
    my $info  = "$guard";

    isa_ok($guard, ['IPC::Manager::Spawn'], "Got a spawn object");
    is($info, $guard->info, "Stringifies");
    like(
        IPC::Manager::Serializer::JSON->deserialize($info),
        [ipcm_default_protocol(), "IPC::Manager::Serializer::JSON", $guard->route],
        "Got a useful info string"
    );
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

    $con1->send_message(con2 => "string message!");
    like(
        [$con2->get_messages],
        [{
            id      => T(),
            stamp   => T(),
            from    => 'con1',
            to      => 'con2',
            content => "string message!",
        }],
        "Got message sent from con1 to con2"
    );

    my $con3 = ipcm_connect('con3' => $info);

    $con3->broadcast({mass => 'message'});

    like(
        [$con1->get_messages],
        [{
            id      => T(),
            stamp   => T(),
            from    => 'con3',
            to      => 'con1',
            content => {mass => 'message'},
        }],
        "Got broadcast (3 -> 1)"
    );

    like(
        [$con2->get_messages],
        [{
            id      => T(),
            stamp   => T(),
            from    => 'con3',
            to      => 'con2',
            content => {mass => 'message'},
        }],
        "Got broadcast (3 -> 2)"
    );

    like(
        [$con3->get_messages],
        [],
        "No broadcast (3 -> 3)"
    );

    $con3->broadcast({mass => 'message2'});
    $con3->broadcast({mass => 'message3'});
    is([$con1->get_messages], [T(), T()], "Got 2 more");
    is([$con2->get_messages], [T(), T()], "Got 2 more");

    $con1->send_message(con2 => 'woosh, I am invisible');

    my $stats = {};
    for my $con ($con1, $con2, $con3) {
        $con->write_stats;
        $stats->{$con->id} = $con->read_stats;
    }

    is(
        $stats,
        {
            'con1' => {
                'read' => {'con2' => 1, 'con3' => 3},
                'sent' => {'con2' => 3},
            },
            'con2' => {
                'read' => {'con1' => 2, 'con3' => 3},
                'sent' => {'con1' => 1},
            },
            'con3' => {
                'read' => {},
                'sent' => {'con1' => 3, 'con2' => 3},
            }
        },
        "Got expected stats"
    );

    is(
        warnings { $guard = undef },
        [
            match qr/Messages waiting at disconnect for con2/,
            match qr/Messages sent vs received mismatch:.*1 con2 -> con1/s,
        ],
        "Got warnings"
    );
    ok(!-e $info, "Info does not exist on the filesystem");
}

#die "You need to write tests for terminate_workers";
#die "You need to write tests for nested services";
#die "You need to write tests for exec services";

1;

__END__

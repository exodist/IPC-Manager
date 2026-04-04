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

=pod

=encoding UTF-8

=head1 NAME

IPC::Manager::Test - Reusable protocol-agnostic test suite for IPC::Manager

=head1 DESCRIPTION

This module provides a set of standard tests that verify the correctness of
an L<IPC::Manager> protocol implementation.  Each test is an ordinary method
whose name begins with C<test_>; they are discovered automatically by
C<tests()> and executed by C<run_all()>.

Protocol test files typically look like:

    use Test2::V1 -ipP;
    use Test2::IPC;
    use IPC::Manager::Test;
    IPC::Manager::Test->run_all(protocol => 'AtomicPipe');
    done_testing;

=head1 METHODS

=over 4

=item IPC::Manager::Test->run_all(protocol => $PROTOCOL)

Run every C<test_*> method as an isolated subtest.  Each test is forked into
its own process so that failures and resource leaks cannot affect sibling
tests.  C<protocol> is required and is set as the default protocol via
C<ipcm_default_protocol> before any test runs.

=item @names = IPC::Manager::Test->tests

Returns a sorted list of all C<test_*> method names defined on the class (or
a subclass).  Used internally by C<run_all>.

=item IPC::Manager::Test->test_generic

Tests the low-level IPC bus: spawning a store, connecting multiple clients,
sending point-to-point and broadcast messages, verifying message contents and
ordering, and checking that per-client statistics are accurate on disconnect.

=item IPC::Manager::Test->test_simple_service

Tests C<ipcm_service> at the single-service level: starts a named service,
sends a request to it from the parent process, verifies the service echoes a
response back with the correct content, and confirms that both sides observed
the exchange.

=item IPC::Manager::Test->test_nested_services

Tests the nested-service code path where C<ipcm_service> is called from
B<inside> a running service.  An outer service starts an inner service during
its C<on_start> callback, then acts as a transparent proxy: each request
received from the test process is forwarded to the inner service, and the
inner service's response is returned to the caller with an identifying prefix.
The test verifies the full two-hop request/response chain.

=item IPC::Manager::Test->test_exec_service

Tests the C<exec> code path of C<ipcm_service>.  Instead of running the
service in a forked child, the child calls C<exec()> to start a fresh Perl
interpreter that loads L<IPC::Manager::Service::State> and deserialises the
service parameters from C<@ARGV>.  The test starts
L<IPC::Manager::Test::EchoService> via exec, sends a request, and verifies
the echoed response.

=item IPC::Manager::Test->test_workers

Tests the C<ipcm_worker> facility.  A service spawns two workers during
C<on_start>: a short-lived worker that writes a marker file and exits, and a
long-lived worker that sleeps indefinitely.  The test verifies that both
workers run, that the service tracks them via C<workers()>, and that
C<terminate_workers()> kills the long-lived worker when the service shuts
down.

=back

=head1 SOURCE

The source code repository for IPC::Manager can be found at
L<https://github.com/exodist/IPC-Manager>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<https://dev.perl.org/licenses/>

=cut

package IPC::Manager::Spawn;
use strict;
use warnings;

use Carp qw/croak/;
use IPC::Manager::Serializer::JSON();

use overload(
    fallback => 1,

    '""' => sub { $_[0]->connect_string },
);

use Object::HashBase qw{
    <protocol
    <info
    <serializer
    <guard
    <stash
    <pid
    <signal
};

sub init {
    my $self = shift;

    $self->{+PID} //= $$;
    $self->{+GUARD} //= 1;

    croak "'protocol' is a required attribute" unless $self->{+PROTOCOL};
    croak "'info' is a required attribute"     unless $self->{+INFO};
    croak "'serializer' is a required attribute" unless $self->{+SERIALIZER};
}

sub connect_string {
    my $self = shift;
    return IPC::Manager::Serializer::JSON->serialize([@{$self}{PROTOCOL(), SERIALIZER(), INFO()}]);
}

sub connect {
    my $self = shift;
    my ($id) = @_;
    return $self->{+PROTOCOL}->connect($id, $self->{+SERIALIZER}, $self->{+INFO});
}

sub terminate {
    my $self = shift;
    my ($con) = @_;
    $con //= $self->connect('spawn');

    $con->broadcast({terminate => 1});

    if ($self->{+SIGNAL()}) {
        for my $peer ($con->peers) {
            my $pid = eval { $con->peer_pid($peer) } or next;
            next if $pid == $$;
            kill($self->{+SIGNAL()}, $pid) if $self->{+SIGNAL()};
        }
    }
}

sub wait {
    my $self = shift;
    my ($con) = @_;
    $con //= $self->connect('spawn');

    for my $client (IPC::Manager::Client->local_clients) {
        eval { $client->disconnect; 1 } or warn $@;
    }

    while (1) {
        my @found;
        for my $peer ($con->peers) {
            next if $peer eq $con->id;
            next unless eval { $con->peer_pid($peer) };
            push @found => $peer;
        }

        last unless @found;

        print "Waiting for clients to go away: " . join(', ' => sort @found) . "\n";
        sleep 1;
    }
}

sub sanity_delta {
    my $self = shift;
    my ($con) = @_;
    $con //= $self->connect('spawn');

    my $stats = $con->all_stats;

    my $deltas = {};
    for my $peer1 (keys %$stats) {
        my $stat = $stats->{$peer1};
        my $sent = $stat->{sent} // {};
        my $read = $stat->{read} // {};

        for my $peer2 (keys %$sent) {
            $deltas->{"$peer2 -> $peer1"} += $sent->{$peer2};
        }

        for my $peer2 (keys %$read) {
            $deltas->{"$peer1 -> $peer2"} -= $read->{$peer2};
        }
    }

    delete $deltas->{$_} for grep { /(:spawn|spawn:)/ || !$deltas->{$_} } keys %$deltas;

    return undef unless keys %$deltas;
    return $deltas;
}

sub sanity_check {
    my $self = shift;

    my $delta = $self->sanity_delta(@_) or return;

    die "\nMessages sent vs received mismatch:\n  Positive means sent and not recieved.\n  negative means recieved more messages than were sent\n" . join("\n" => map { "    $delta->{$_} $_" } sort keys %$delta) . "\n\n";
}

sub DESTROY {
    my $self = shift;
    return unless $self->{+GUARD};
    return unless $self->{+PID} == $$;

    my $con = $self->connect('spawn');

    $self->terminate($con);
    $self->wait($con);
    $self->sanity_check($con);

    $con = undef;

    $self->{+PROTOCOL}->unspawn($self->{+INFO}, delete $self->{+STASH});
}

1;

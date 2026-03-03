package IPC::Manager::Coordinator::Process;
use strict;
use warnings;

use Carp qw/croak/;

use IPC::Manager::Util qw/require_mod/;

use Object::HashBase qw{
    <via
    <name
    <real_io
    +peer_cache
    +client
};

sub init {
    my $self = shift;

    croak "'via' is required" unless $self->{+VIA};

    my $io = $self->{+REAL_IO} or croak "'real_io' is required";
    croak "'real_io' must be a hashref"   unless ref($io) eq 'HASH';
    croak "'real_io->{stdout}' is required" unless $io->{stdout};
    croak "'real_io->{stderr}' is required" unless $io->{stderr};
}

sub pid       { croak "Not Implemented" }
sub terminate { croak "Not Implemented" }

sub client { $_[0]->{+CLIENT} //= IPC::Manager->ipcm_connect($_[0]->{+NAME}, $_[0]->{+VIA}) }

sub kill {
    my $self = shift;
    my ($sig) = @_;
    $sig //= 'TERM';
    CORE::kill($sig, $self->pid);
}

sub debug {
    my $self = shift;

    my $io = $self->{+REAL_IO}->{stderr};
    print $io @_;
}

sub peer {
    my $self = shift;
    my ($name, @params) = @_;

    croak "Too many arguments (new peers can not be created from this handle)" if @params;

    return $self->get_peer($name);
}

sub get_peer {
    my $self = shift;
    my ($name) = @_;

    return $self->{+PEER_CACHE}->{$name} if $self->{+PEER_CACHE}->{$name};

    require IPC::Manager::Coordinator::Peer;
    return $self->{+PEER_CACHE}->{$name} = IPC::Manager::Coordinator::Peer->new(
        NAME()    => $name,
        VIA()     => $self->{+VIA},
        CLIENT()  => $self->client,
        REAL_IO() => $self->{+REAL_IO},
    );
}

1;

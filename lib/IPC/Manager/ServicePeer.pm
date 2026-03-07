package IPC::Manager::ServicePeer;
use strict;
use warnings;

use Carp qw/croak/;
use Scalar::Util qw/weaken/;

use Object::HashBase qw{
    <name
    <service
};

sub init {
    my $self = shift;

    croak "'name' is required" unless $self->{+NAME};

    my $service = $self->{+SERVICE} or croak "'service' is required";

    croak "'service' must be the current process" unless $service->pid == $$;

    weaken($self->{+SERVICE});

    return;
}

sub send_request {
    my $self = shift;
    my ($req, $cb) = @_;
    $self->{+SERVICE}->send_request($self->{+NAME}, $req, $cb);
}

sub get_response {
    my $self = shift;
    my ($id) = @_;
    $self->{+SERVICE}->get_response($id);
}

1;

package IPC::Manager::Coordinator::Peer;
use strict;
use warnings;

use parent 'IPC::Manager::Coordinator::Process';
use Object::HashBase qw{
    <xxx
};

sub peer { croak "peer() should not be called on a peer" }

sub pid { $self->client->peer_pid }

sub terminate {
}

sub request {

}

sub message {

}

1;

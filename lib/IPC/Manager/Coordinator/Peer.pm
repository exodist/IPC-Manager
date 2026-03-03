package IPC::Manager::Coordinator::Peer;
use strict;
use warnings;

use parent 'IPC::Manager::Coordinator::Process';
use Object::HashBase qw{

};

sub peer { croak "peer() should not be called on a peer" }

sub request {

}

1;

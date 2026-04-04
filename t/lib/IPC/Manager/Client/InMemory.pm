package IPC::Manager::Client::InMemory;
use strict;
use warnings;

use Carp qw/croak/;

use parent 'IPC::Manager::Client';
use Object::HashBase;

use IPC::Manager::Message;

# Global in-memory store keyed by route.
# Each route contains:
#   clients => { id => { pid => $$, messages => [] } }  -- active clients
#   stats   => { id => { read => {}, sent => {} } }     -- persisted after disconnect
my %STORES;

sub viable { 1 }

sub spawn {
    my $class  = shift;
    my %params = @_;

    my $route = "inmemory-" . ++$IPC::Manager::Client::InMemory::_COUNTER;

    $STORES{$route} = { clients => {}, stats => {} };

    return $route;
}

sub unspawn {
    my $class = shift;
    my ($route) = @_;
    delete $STORES{$route};
}

sub peer_exists_in_store {
    my $class = shift;
    my ($route) = @_;
    return exists $STORES{$route} ? 1 : 0;
}

sub _store {
    my $self = shift;
    return $STORES{$self->{route}} // croak "Route '$self->{route}' does not exist";
}

sub _client_data {
    my $self = shift;
    my $store = $self->_store;
    return $store->{clients}{$self->{id}} // croak "Client '$self->{id}' not registered";
}

sub init {
    my $self = shift;

    $self->SUPER::init();

    my $store = $self->_store;
    my $id    = $self->{id};

    if ($self->{reconnect}) {
        croak "Client '$id' does not exist" unless $store->{clients}{$id};
        my $data = $store->{clients}{$id};
        croak "Connection already running in pid $data->{pid}"
            if $data->{pid} && $data->{pid} != $$ && kill(0, $data->{pid});
    }
    else {
        croak "Client '$id' already exists" if $store->{clients}{$id};
        $store->{clients}{$id} = {
            pid      => $$,
            messages => [],
        };
    }

    $store->{clients}{$id}{pid} = $$;
}

sub pending_messages { 0 }

sub ready_messages {
    my $self = shift;
    my $data = eval { $self->_client_data } or return 0;
    return @{$data->{messages}} ? 1 : 0;
}

sub get_messages {
    my $self = shift;
    $self->pid_check;
    my $data = $self->_client_data;
    my @raw  = splice @{$data->{messages}};
    my @out;
    for my $msg (@raw) {
        $self->{stats}{read}{$msg->{from}}++;
        push @out, $msg;
    }
    return sort { $a->stamp <=> $b->stamp } @out;
}

sub send_message {
    my $self = shift;
    my $msg  = $self->build_message(@_);
    $self->pid_check;

    my $peer_id = $msg->to or croak "Message has no peer";
    my $store   = $self->_store;

    croak "Client '$peer_id' does not exist"
        unless $store->{clients}{$peer_id};

    push @{$store->{clients}{$peer_id}{messages}}, $msg;
    $self->{stats}{sent}{$peer_id}++;
}

sub peers {
    my $self  = shift;
    my $store = $self->_store;
    return sort grep { $_ ne $self->{id} } keys %{$store->{clients}};
}

sub peer_exists {
    my $self = shift;
    my ($peer_id) = @_;
    croak "'peer_id' is required" unless $peer_id;
    my $store = $self->_store;
    return $store->{clients}{$peer_id} ? 1 : undef;
}

sub peer_pid {
    my $self = shift;
    my ($peer_id) = @_;
    my $store = $self->_store;
    my $data  = $store->{clients}{$peer_id} or return undef;
    return $data->{pid};
}

sub write_stats {
    my $self  = shift;
    my $store = eval { $self->_store } or return;
    $store->{stats}{$self->{id}} = $self->{stats};
}

sub read_stats {
    my $self  = shift;
    my $store = $self->_store;
    return $store->{stats}{$self->{id}} // {read => {}, sent => {}};
}

sub all_stats {
    my $self  = shift;
    my $store = $self->_store;
    my %out;
    for my $id (keys %{$store->{stats}}) {
        $out{$id} = $store->{stats}{$id};
    }
    return \%out;
}

sub pre_disconnect_hook {
    my $self  = shift;
    my $store = eval { $self->_store } or return;
    delete $store->{clients}{$self->{id}};
}

1;

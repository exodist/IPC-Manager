package IPC::Manager::Protocol;
use strict;
use warnings;

use Carp qw/croak confess/;
use Scalar::Util qw/blessed/;
use IPC::Manager::Util qw/pid_is_running/;
use IPC::Manager::Message;

use Object::HashBase qw{
    <is_manager
    <is_spawned
    <spawn_pid
    <manager_pid
    <pid
    <id
    <info
    <disconnected
    <serializer
    +reconnect
};

# Must implement
sub clients          { croak "Not Implemented" }
sub get_messages     { croak "Not Implemented" }
sub pending_messages { croak "Not Implemented" }
sub ready_messages   { croak "Not Implemented" }
sub listen           { croak "Not Implemented" }
sub broadcast        { croak "Not Implemented" }
sub requeue_message  { croak "Not Implemented" }
sub send_message     { croak "Not Implemented" }
sub client_pid       { croak "Not Implemented" }
sub client_exists    { croak "Not Implemented" }
sub client_remote    { croak "Not Implemented" }

# May override
sub ready     { 1 }
sub is_client { return $_[0]->is_manager ? 0 : 1 }

# Optional
sub iterate               { }
sub pre_disconnect_hook   { }
sub post_disconnect_hook  { }
sub pre_suspend_hook      { }
sub post_suspend_hook     { }
sub instance_cleanup_hook { }
sub manager_cleanup_hook  { }

sub pid_check { croak "Called from wrong pid" if $_[0]->{+PID} != $$ }

sub init {
    my $self = shift;

    croak "'info' is a required attribute" unless $self->{+INFO};

    my $id = $self->{+ID} // croak "'id' is a required attribute";

    croak "'id' may not begin with an underscore" if $id =~ m/^_/;

    $self->{+PID} //= $$;
    $self->{+IS_MANAGER} //= 0;

    my $ser = $self->{+SERIALIZER} //= do {
        require IPC::Manager::Serializer::JSON;
        'IPC::Manager::Serializer::JSON';
    };

    croak "'$ser' is not a valid serializer" unless $ser->isa('IPC::Manager::Serializer');
}

sub terminate {
    my $self = shift;

    my $msg = IPC::Manager::Message->new(
        content   => {terminate => 1},
        broadcast => 1,
        from      => $self->{+ID},
    );

    local $MAIN::DEBUG = 1;
    $self->broadcast($msg);
}

sub connect {
    my $class = shift;
    my ($info, $pid, $id) = @_;

    return $class->new(INFO() => $info, ID() => $id, IS_MANAGER() => 0, PID() => $pid);
}

sub reconnect {
    my $class = shift;
    my ($info, $pid, $id) = @_;

    return $class->new(INFO() => $info, ID() => $id, IS_MANAGER() => 0, PID() => $pid, RECONNECT() => 1);
}

sub disconnect {
    my $self = shift;
    my ($handler) = @_;

    $self->pid_check;

    return if $self->{+DISCONNECTED};

    $self->pre_disconnect_hook;

    # Wait for any messages that are still being written
    sleep 0.2 while $self->pending_messages;

    if (my @ready = $self->get_messages) {
        @ready = grep { !$_->is_terminate } @ready;
        if (@ready) {
            if ($handler) {
                $self->$handler(\@ready);
            }
            else {
                confess 'messages waiting at disconnect';
            }
        }
    }

    $self->{+DISCONNECTED} = 1;

    $self->post_disconnect_hook;
}

sub suspend {
    my $self = shift;
    $self->pid_check;

    $self->pre_suspend_hook;

    $self->{+DISCONNECTED} = 1;

    $self->post_suspend_hook;
}

sub spawn {
    my $class = shift;

    my $self = $class->listen(@_);

    $self->{+IS_SPAWNED} = 1;

    return $self;
}

sub post_fork_parent {
    my $self = shift;
    my ($child_pid) = @_;
    $self->{+SPAWN_PID} = $child_pid;
    $self->{+MANAGER_PID} = $$;
    $self->{+PID} = $child_pid;
}

sub post_fork_child {
    my $self = shift;
    my ($parent_pid) = @_;
    $self->{+SPAWN_PID} = $$;
    $self->{+MANAGER_PID} = $parent_pid;
    $self->{+PID} = $$;
}

sub client_running {
    my $self = shift;
    my ($client_id) = @_;

    return 0 unless $self->client_exists($client_id);
    return -1 if $self->client_remote($client_id);

    my $pid = $self->client_pid($client_id);
    return pid_is_running($pid) ? 1 : 0;
}

sub DESTROY {
    my $self = shift;

    if ($self->{+PID} == $$) {
        $self->disconnect unless $self->{+DISCONNECTED};
        $self->instance_cleanup_hook();
    }

    if ($self->{+IS_MANAGER} && $self->{+MANAGER_PID} == $$) {
        IPC::Manager::Client->disconnect_local_clients(blessed($self), $self->{+INFO});

        while (my @clients = $self->clients) {
            print STDERR "Waiting on: " . join(', ' => sort @clients) . "\n";
            sleep 1;
        }

        $self->manager_cleanup_hook();
    }
}

1;

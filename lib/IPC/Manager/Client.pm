package IPC::Manager::Client;
use strict;
use warnings;

use Carp qw/croak/;
use Scalar::Util qw/blessed weaken/;

use IPC::Manager::Util qw/pid_is_running/;

use IPC::Manager::Message;

use Object::HashBase qw{
    <id
    <pid
    <info
    <disconnected
    <serializer
    +reconnect
    <stats
};

my ($PID, @LOCAL);

sub local_clients {
    return unless $PID;
    if ($PID != $$) {
        $PID = $$;
        return @LOCAL = ();
    }

    return grep { $_ } @LOCAL;
}

sub unspawn              { }
sub pre_disconnect_hook  { }
sub pre_suspend_hook     { }
sub post_suspend_hook    { }
sub post_disconnect_hook { }

sub reconnect { shift->connect(@_, reconnect => 1) }
sub pid_check { croak "Client used from wrong PID" if $_[0]->{+PID} != $$; $_[0] }

sub have_pending_messages { 0 }
sub have_ready_messages   { croak "Not Implemented" }

sub get_messages { croak "Not Implemented" }
sub peer_exists  { croak "Not Implemented" }
sub peer_pid     { croak "Not Implemented" }
sub peers        { croak "Not Implemented" }
sub send_message { croak "Not Implemented" }
sub vivify_info  { croak "Not Implemented" }
sub write_stats  { croak "Not Implemented" }
sub read_stats   { croak "Not Implemented" }

sub spawn {
    my $class  = shift;
    my %params = @_;

    my ($info, $stash) = $class->vivify_info(%params);

    require IPC::Manager::Spawn;
    return IPC::Manager::Spawn->new(
        %params,
        protocol => $class,
        info     => $info,
        stash    => $stash,
    );
}

sub connect {
    my $class = shift;
    my ($id, $serializer, $info, %params) = @_;
    return $class->new(%params, SERIALIZER() => $serializer, INFO() => $info, ID() => $id);
}

sub init {
    my $self = shift;

    if (!$PID || $PID != $$) {
        $PID = $$;
        @LOCAL = ();
    }

    push @LOCAL => $self;
    weaken($LOCAL[-1]);

    croak "'serializer' is a required attribute" unless $self->{+SERIALIZER};
    croak "'info' is a required attribute"       unless $self->{+INFO};

    my $id = $self->{+ID} // croak "'id' is a required attribute";

    croak "'id' may not begin with an underscore" if $id =~ m/^_/;

    $self->{+PID} //= $$;
    $self->{+STATS} = $self->read_stats if $self->{+RECONNECT};
    $self->{+STATS} //= {read => {}, sent => {}};
}

sub build_message {
    my $self = shift;
    my $in = @_ % 2 ? shift(@_) : undef;
    if (@_ == 2 && $_[1] ne 'content') {
        @_ = (to => $_[0], content => $_[1]);
    }
    return IPC::Manager::Message->new(($in ? %$in : ()), from => $self->{+ID}, @_);
}

sub broadcast {
    my $self = shift;

    if (@_ == 1 && !(blessed($_[0]) && $_[0]->isa('IPC::Manager::Message'))) {
        @_ = (content => $_[0]);
    }

    my %out;
    for my $peer ($self->peers) {
        my ($ok, $err) = $self->try_message(@_, to => $peer, broadcast => 1, id => undef);
        $out{$peer} = $ok ? {sent => 1} : {sent => 0, error => $err};
    }

    return \%out;
}

sub try_message {
    my $self = shift;
    my $args = \@_;

    my ($ok, $err);
    {
        local $@;
        if (eval { $self->send_message(@$args); 1 }) {
            $ok = 1;
        }
        else {
            $ok = 0;
            $err = $@ // "unknown error";
        }
    }

    return ($ok, $err) if wantarray;

    $@ = $err;
    return $ok;
}

sub requeue_message {
    my $self = shift;
    $self->send_message(@_, to => $self->{+ID});
}

sub peer_active {
    my $self = shift;

    my $peer_pid = $self->peer_pid(@_);

    return 0 unless $peer_pid;
    return 0 unless pid_is_running($peer_pid);
    return 0 unless kill(0, $peer_pid);
    return 1;
}

sub disconnect {
    my $self = shift;
    my ($handler) = @_;

    $self->pid_check;

    return if $self->{+DISCONNECTED};

    $self->pre_disconnect_hook;

    # Wait for any messages that are still being written
    my $err;
    while ($self->pending_messages || $self->ready_messages) {
        if (my @ready = $self->get_messages) {
            @ready = grep { !$_->is_terminate } @ready;
            if (@ready) {
                if ($handler) {
                    $self->$handler(\@ready);
                }
                else {
                    $self->{+STATS}->{read}->{$_->{from}}-- for @ready;
                    $err = "Messages waiting at disconnect for $self->{+ID}";
                    last;
                }
            }
        }
    }

    $self->{+DISCONNECTED} = 1;

    $self->post_disconnect_hook;

    $self->write_stats;

    croak $err if $err;
}

sub suspend {
    my $self = shift;
    $self->pid_check;

    $self->pre_suspend_hook;

    $self->{+DISCONNECTED} = 1;

    $self->post_suspend_hook;
    $self->write_stats;
}

sub DESTROY {
    my $self = shift;
    return unless $self->{+PID} && $self->{+PID} == $$;
    local $@;
    eval { $self->disconnect;  1 } or warn $@;
    eval { $self->write_stats; 1 } or warn $@;
}

1;

package IPC::Manager::Client::UnixSocket;
use strict;
use warnings;

use File::Spec;
use Carp qw/croak/;
use POSIX qw/mkfifo/;
use IO::Socket::UNIX qw/SOCK_DGRAM/;
use IO::Select;

use parent 'IPC::Manager::Base::FS';
use Object::HashBase qw{
    +buffer
    +socket
    +select
};

sub check_path { -S $_[1] }
sub path_type  { 'UNIX Socket' }

sub suspend { croak "suspend is not supported by the UnixSocket driver" }

sub make_path {
    my $self = shift;
    my $path = $self->path;

    my $s = IO::Socket::UNIX->new(
        Type     => SOCK_DGRAM,
        Local    => $path,
        Blocking => 0,
    ) or die "Cannot create reader socket: $!";

    $self->{+SOCKET} = $s;
}

sub pre_disconnect_hook {
    my $self = shift;
    unlink($self->{+PATH}) or warn "Could not unlink socket: $!";
}

sub init {
    my $self = shift;

    $self->{+BUFFER} //= [];

    $self->SUPER::init();
}

sub select {
    my $self = shift;

    return $self->{+SELECT} if $self->{+SELECT};

    my $sel = IO::Select->new;
    $sel->add($self->{+SOCKET});

    return $self->{+SELECT} = $sel;
}

sub pending_messages {
    my $self = shift;

    $self->pid_check;

    return 1 if $self->have_resume_file;
    return 1 if @{$self->{+BUFFER}};

    my $sel = $self->select;

    return 1 if $sel->can_read(0);
    return 0;
}

sub ready_messages {
    my $self = shift;

    $self->pid_check;

    return 1 if $self->have_resume_file;

    return 1 if @{$self->{+BUFFER}};

    return 0 unless $self->pending_messages;

    my $s = $self->{+SOCKET};
    while (my $msg = <$s>) {
        push @{$self->{+BUFFER}} => $msg;
    }

    return 0;
}

sub get_messages {
    my $self = shift;

    my @out;

    push @out => $self->read_resume_file;
    push @out => @{$self->{+BUFFER}};

    my $s = $self->{+SOCKET};
    while (my $msg = <$s>) {
        $msg = IPC::Manager::Message->new($self->{+SERIALIZER}->deserialize($msg));
        push @out => $msg;
        $self->{+STATS}->{read}->{$msg->{from}}++;
    }

    @{$self->{+BUFFER}} = ();

    return sort { $a->stamp <=> $b->stamp } @out;
}

sub send_message {
    my $self = shift;
    my $msg = $self->build_message(@_);

    my $peer_id = $msg->to or croak "No peer specified";

    $self->pid_check;
    my $sock = $self->peer_exists($peer_id) or die "'$peer_id' is not a valid message recipient";

    my $s = IO::Socket::UNIX->new(
        Type => SOCK_DGRAM,
        Peer => $sock,
    ) or die "Cannot connect to socket: $!";

    $s->send($self->{+SERIALIZER}->serialize($msg) . "\n") or die "Cannot send message: $!";

    $self->{+STATS}->{sent}->{$msg->{to}}++;
}

1;

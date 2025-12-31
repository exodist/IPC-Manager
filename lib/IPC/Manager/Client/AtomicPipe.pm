package IPC::Manager::Client::AtomicPipe;
use strict;
use warnings;

use File::Spec;
use Atomic::Pipe;
use Carp qw/croak/;
use POSIX qw/mkfifo/;

use parent 'IPC::Manager::Base::FS';
use Object::HashBase qw{
    permissions
    +pipe
    +buffer
};

sub check_path { -p $_[1] }
sub path_type  { 'FIFO' }

sub make_path {
    my $self  = shift;
    my $path  = $self->path;
    my $perms = $self->{+PERMISSIONS} //= 0700;
    mkfifo($path, $perms) or die "Failed to make fifo '$path': $!";
    my $p = Atomic::Pipe->read_fifo($path);
    $p->blocking(0);
    $p->resize_or_max($p->max_size) if $p->max_size;

    $self->{+PIPE} = $p;
}

sub pre_disconnect_hook {
    my $self = shift;
    unlink($self->{+PATH}) or warn "Could not unlink fifo: $!";
}

sub init {
    my $self = shift;

    $self->SUPER::init();

    $self->{+BUFFER} //= [];
}

sub pre_suspend_hook {
    my $self = shift;

    $self->pid_check;

    # Get all messages and re-queue them
    my $p = $self->{+PIPE};

    my @msgs;
    while ($p->{$p->IN_BUFFER_SIZE}) {
        push @msgs => $p->read_message;
    }

    if (@msgs) {
        $self->requeue_message(@msgs);
    }

    $self->SUPER::pre_suspend_hook(@_);
}

sub pending_messages {
    my $self = shift;

    $self->pid_check;

    return 1 if $self->have_resume_file;

    my $p = $self->{+PIPE};

    $p->fill_buffer;

    if ($p->{$p->IN_BUFFER_SIZE}) {
        push @{$self->{+BUFFER}} => $self->{+PIPE}->read_message;
        return 1;
    }

    return 0;
}

sub ready_messages {
    my $self = shift;

    $self->pid_check;

    return 1 if $self->have_resume_file;

    return 1 if @{$self->{+BUFFER}};

    push @{$self->{+BUFFER}} => $self->{+PIPE}->read_message;

    return 1 if @{$self->{+BUFFER}};
    return 0;
}

sub _process_msg {
    my $self = shift;
    my ($in) = @_;

    my $msg = IPC::Manager::Message->new($self->{+SERIALIZER}->deserialize($in));
    $self->{+STATS}->{read}->{$msg->{from}}++;
    return $msg;
}

sub get_messages {
    my $self = shift;

    my $p = $self->{+PIPE};

    my @out;

    push @out => $self->read_resume_file;

    push @out => map { $self->_process_msg($_) } @{$self->{+BUFFER}};

    while (my $msg = $p->read_message) {
        push @out => $self->_process_msg($msg);
    }

    @{$self->{+BUFFER}} = ();

    return sort { $a->stamp <=> $b->stamp } @out;
}

sub send_message {
    my $self = shift;
    my $msg  = $self->build_message(@_);

    my $peer_id = $msg->to or croak "No peer specified";

    $self->pid_check;
    my $fifo = $self->peer_exists($peer_id) or die "'$peer_id' is not a valid message recipient";

    my $p = Atomic::Pipe->write_fifo($fifo);
    $p->write_message($self->{+SERIALIZER}->serialize($msg));

    $self->{+STATS}->{sent}->{$msg->{to}}++;
}

1;

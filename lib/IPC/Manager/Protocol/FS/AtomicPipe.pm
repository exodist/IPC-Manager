package IPC::Manager::Protocol::FS::AtomicPipe;
use strict;
use warnings;

use File::Spec;
use Atomic::Pipe;
use Carp qw/croak/;
use POSIX qw/mkfifo/;

use parent 'IPC::Manager::Protocol::FS';
use Object::HashBase qw{
    permissions
    +pipe
    +buffer
    +resume_file
};

sub check_path { -p $_[1] }
sub path_type  { 'FIFO' }

sub resume_file {
    my $self = shift;
    return $self->{+RESUME_FILE} //= File::Spec->catfile($self->{+INFO}, $self->{+ID} . ".resume");
}

sub client_pid_file {
    my $self = shift;
    my ($client_id) = @_;

    return File::Spec->catfile($self->{+INFO}, $client_id . ".pid");
}

sub make_path {
    my $self = shift;
    my $path = $self->path;
    my $perms = $self->{+PERMISSIONS} //= 0700;
    mkfifo($path, $perms) or die "Failed to make fifo '$path': $!";
}

sub pre_disconnect_hook {
    my $self = shift;
    unlink($self->{+PATH}) or warn "Could not unlink fifo: $!";
}

sub init {
    my $self = shift;

    $self->SUPER::init();

    my $path = $self->path;
    my $p = Atomic::Pipe->read_fifo($path);
    $p->blocking(0);
    $p->resize_or_max($p->max_size) if $p->max_size;

    $self->{+PIPE} = $p;

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

{
    no warnings 'once';
    *requeue_messages = \&requeue_message;
}
sub requeue_message {
    my $self = shift;
    $self->pid_check;
    open(my $fh, '>>', $self->resume_file) or die "Could not open resume file: $!";
    for my $msg (@_) {
        print $fh $self->{+SERIALIZER}->serialize($msg), "\n";
    }
    close($fh);
}

sub pending_messages {
    my $self = shift;

    $self->pid_check;

    return 1 if -e $self->resume_file;

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

    return 1 if -e $self->resume_file;

    return 1 if @{$self->{+BUFFER}};

    push @{$self->{+BUFFER}} => $self->{+PIPE}->read_message;

    return 1 if @{$self->{+BUFFER}};
    return 0;
}

sub get_messages {
    my $self = shift;

    my $p = $self->{+PIPE};

    my @out;

    push @out => $self->_read_resume_file;
    push @out => @{$self->{+BUFFER}};
    while (my $msg = $p->read_message) {
        push @out => $msg;
    }

    @{$self->{+BUFFER}} = ();

    return sort { $a->stamp <=> $b->stamp } map { IPC::Manager::Message->new($self->{+SERIALIZER}->deserialize($_)) } @out;
}

sub _read_resume_file {
    my $self = shift;

    my @out;

    my $rf = $self->resume_file;
    return @out unless -e $rf;

    open(my $fh, '<', $rf) or die "Could not open resume file: $!";
    while (my $line = <$fh>) {
        push @out => $line;
    }
    close($fh);

    unlink($rf) or die "Could not unlink resume file";

    return @out;
}

sub send_message {
    my $self = shift;
    my ($msg) = @_;

    $self->_send_message($msg, $msg->to);
}

sub _send_message {
    my $self = shift;
    my ($msg, $client_id) = @_;

    $client_id //= $msg->client_id or croak "No client specified";

    $self->pid_check;
    my $fifo = $self->client_exists($client_id) or die "'$client_id' is not a valid message recipient";

    my $p = Atomic::Pipe->write_fifo($fifo);
    $p->write_message($self->{+SERIALIZER}->serialize($msg));
}

sub broadcast {
    my $self = shift;
    my ($msg) = @_;

    $self->_send_message($msg, $_) for $self->clients;
}

1;

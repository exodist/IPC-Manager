package IPC::Manager::Protocol::FS::MessageFiles;
use strict;
use warnings;

use Carp qw/croak confess/;
use File::Spec;

use parent 'IPC::Manager::Protocol::FS';
use Object::HashBase qw{
    +dir_handle
};

sub check_path { -d $_[1] }
sub make_path  { mkdir($_[1]) or die "Could not make dir '$_[1]': $!" }
sub path_type  { 'subdir' }

sub client_pid_file {
    my $self = shift;
    my ($client_id) = @_;

    my $dir = File::Spec->catdir($self->{+INFO}, $client_id);
    return File::Spec->catfile($dir, 'PID');
}

sub pre_disconnect_hook {
    my $self = shift;

    my $new_path = File::Spec->catfile($self->{+INFO}, "_" . $self->{+ID});
    rename($self->path, $new_path) or die "Cannot rename directory: $!";
    $self->{+PATH} = $new_path;
}

sub dir_handle {
    my $self = shift;
    $self->pid_check;
    my $out = $self->{+DIR_HANDLE} //= do {
        opendir(my $dh, $self->path) or die "Could not open dir: $!";
        $dh;
    };

    rewinddir($out);

    return $out;
}

sub pending_messages {
    my $self = shift;
    return $self->message_files('pend') ? 1 : 0;
}

sub ready_messages {
    my $self = shift;
    return $self->message_files('ready') ? 1 : 0;
}

sub message_files {
    my $self = shift;
    $self->pid_check;
    my ($ext) = @_;
    my @out = grep { m/\.\Q$ext\E$/ } readdir($self->dir_handle);
    return @out ? [@out] : undef;
}

sub get_messages {
    my $self = shift;
    my ($ext) = @_;

    my @out;

    my $ready = $self->message_files('ready') or return;

    for my $msg (@$ready) {
        my $full = File::Spec->catfile($self->path, $msg);
        open(my $fh, '<', $full) or die "Could not open file '$full': $!";
        local $/;
        my $content = <$fh>;
        close($full);
        unlink($full) or die "Could not unlink file '$full': $!";
        push @out => $content;
    }

    return sort { $a->stamp <=> $b->stamp } map { IPC::Manager::Message->new($self->{+SERIALIZER}->deserialize($_)) } @out;
}

sub _write_message_file {
    my $self = shift;
    my ($msg, $client) = @_;

    $client //= $msg->to or croak "Message has no client";

    my $msg_dir = $self->client_exists($client) or croak "Client does not exist";
    my $msg_file = File::Spec->catfile($msg_dir, $msg->id);

    my $pend = "$msg_file.pend";
    my $ready = "$msg_file.ready";

    confess "Message file '$msg_file' already exists" if -e $pend || -e $ready;

    open(my $fh, '>', $pend) or die "Could not open '$pend': $!";

    print $fh $self->{+SERIALIZER}->serialize($msg);

    close($fh);

    rename($pend, $ready) or die "Could not rename file: $!";

    return $ready;
}

sub broadcast {
    my $self = shift;
    my ($msg) = @_;

    $self->pid_check;

    $self->_write_message_file($msg, $_) for $self->clients;
}

sub requeue_message {
    my $self = shift;
    my ($msg) = @_;
    $self->pid_check;
    $self->_write_message_file($msg, $self->{+ID});
}

sub send_message {
    my $self = shift;
    my ($msg) = @_;
    $self->pid_check;
    $self->_write_message_file($msg);
}

1;

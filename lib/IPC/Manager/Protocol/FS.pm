package IPC::Manager::Protocol::FS;
use strict;
use warnings;

use Carp qw/croak/;
use File::Temp qw/tempdir/;
use File::Path qw/remove_tree/;
use IPC::Manager::Util qw/pid_is_running/;
use File::Spec;

use parent 'IPC::Manager::Protocol';
use Object::HashBase qw{
    +path
    +pidfile
    +resume_file
};

sub ready { -d $_[0]->{+INFO} }

sub check_path { croak "Not Implemented" }
sub make_path  { croak "Not Implemented" }
sub path_type  { croak "Not Implemented" }

sub resume_file {
    my $self = shift;
    return $self->{+RESUME_FILE} //= File::Spec->catfile($self->{+INFO}, $self->{+ID} . ".resume");
}

sub have_resume_file { -e $_[0]->resume_file }

sub client_pid_file {
    my $self = shift;
    my ($client_id) = @_;

    return File::Spec->catfile($self->{+INFO}, $client_id . ".pid");
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

sub read_resume_file {
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

sub pidfile {
    my $self = shift;
    return $self->{+PIDFILE} //= $self->client_pid_file($self->{+ID});
}

sub path {
    my $self = shift;
    return $self->{+PATH} //= File::Spec->catfile($self->{+INFO}, $self->{+ID});
}

sub init {
    my $self = shift;

    $self->SUPER::init();

    my $id   = $self->{+ID};
    my $path = $self->path;

    my $pt = $self->path_type;

    if ($self->{+RECONNECT}) {
        croak "${id} ${pt} does not exist" unless $self->check_path($path);
        my $pidfile = $self->pidfile;
        if (open(my $fh, '<', $pidfile)) {
            chomp(my $pid = <$fh>);
            croak "Looks like the connection is already running in pid $pid" if $pid && pid_is_running($pid);
            close($fh);
        }
    }
    else {
        croak "${id} ${pt} already exists" if -e $path;
        $self->make_path($path);
    }

    $self->write_pid;
}

sub listen {
    my $class = shift;
    my (%params) = @_;

    my $template = $params{template} // "PerlIPCManager-$$-XXXXXX";

    my $id = 'manager';
    my $dir = tempdir($template, TMPDIR => 1, CLEANUP => 0);

    return $class->new(%params, INFO() => $dir, ID() => 'manager', IS_MANAGER() => 1, MANAGER_PID() => $$);
}

sub clear_pid {
    my $self = shift;

    my $pidfile = $self->pidfile;
    unlink($pidfile) or die "Could not unlink pidfile '$pidfile': $!";
}

sub write_pid {
    my $self = shift;

    my $pidfile = $self->pidfile;
    open(my $fh, '>', $pidfile) or die "Could not open pidfile '$pidfile': $!";
    print $fh $self->{+PID};
    close($fh);
}

sub post_fork_child {
    my $self = shift;
    $self->SUPER::post_fork_child(@_);
    $self->write_pid;
}

sub post_disconnect_hook {
    my $self = shift;
    remove_tree($self->path, {keep_root => 0, safe => 1});
}

sub pre_suspend_hook {
    my $self = shift;
    $self->clear_pid;
}

sub clients {
    my $self = shift;

    my @out;

    opendir(my $dh, $self->{+INFO}) or die "Could not open dir: $!";
    for my $file (readdir($dh)) {
        next if $file eq $self->{+ID};
        next if $file =~ m/^(\.|_)/;
        next if $file =~ m/\.pid$/;
        $self->client_exists($file) or next;

        push @out => $file;
    }

    close($dh);

    return sort @out;
}

sub client_pid {
    my $self = shift;
    my ($client_id) = @_;

    my $path = $self->client_exists($client_id) or return undef;
    my $pidfile = $self->client_pid_file($client_id);
    return 0 unless -f $pidfile;
    open(my $fh, '<', $pidfile) or return 0;
    chomp(my $pid = <$fh>);
    close($fh);
    return $pid;
}

sub client_exists {
    my $self = shift;
    my ($client_id) = @_;

    croak "'client_id' is required" unless $client_id;

    my $path = File::Spec->catdir($self->{+INFO}, $client_id);
    return $path if $self->check_path($path);
    return undef;
}

sub manager_cleanup_hook {
    my $self = shift;
    remove_tree($self->{+INFO}, {keep_root => 0, safe => 1});
}

1;

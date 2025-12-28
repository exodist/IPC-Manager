package IPC::Manager::Protocol::DBI;
use strict;
use warnings;

use Carp qw/croak/;
use File::Temp qw/tempfile/;
use IPC::Manager::Util qw/pid_is_running/;

use DBI;

use parent 'IPC::Manager::Protocol';
use Object::HashBase qw{
    +dbh
    <user
    <pass
    <attrs
};

sub dsn       { croak "Not Implemented" }
sub ready     { croak "Not Implemented" }
sub table_sql { croak "Not Implemented" }

sub escape { '' }

sub pending_messages { 0 }
sub ready_messages   { $_[0]->_get_message_ids ? 1 : 0 }

sub post_fork_child {
    my $self = shift;
    $self->SUPER::post_fork_child();
    delete $self->{+DBH};
}

sub post_fork_parent {
    my $self = shift;
    $self->SUPER::post_fork_parent();
    delete $self->{+DBH};
}

sub dbh {
    $_[0]->pid_check;
    $_[0]->{+DBH} //= DBI->connect($_[0]->dsn, $_[0]->user, $_[0]->pass, $_[0]->attrs) or die "Could not connect";
}

sub init_db {
    my $self = shift;

    my $dbh = $self->dbh;

    for my $sql ($self->table_sql) {
        $dbh->do($sql) or die $dbh->errstr;
    }
}

sub default_attrs {}

sub init {
    my $self = shift;

    $self->SUPER::init();

    $self->{+USER} //= delete $self->{username} // '';
    $self->{+PASS} //= delete $self->{password} // '';

    $self->{+ATTRS} //= $self->default_attrs;

    my $id = $self->{+ID};

    $self->init_db if $self->is_manager;

    if ($self->{+RECONNECT}) {
        my $row = $self->_get_client($self->{+ID}) or die "The '$id' client does not exist";

        if (my $pid = $row->{pid}) {
            croak "Looks like the connection is already running in pid $pid" if $pid && pid_is_running($pid);
        }
    }
    else {
        my $dbh = $self->dbh;
        my $e   = $self->escape;
        my $sth = $dbh->prepare("INSERT INTO ipcm_clients(${e}id${e}, ${e}pid${e}) VALUES (?, ?)") or die $dbh->errstr;
        $sth->execute($id, $self->{+PID}) or die $dbh->errstr;
    }
}

sub clients {
    my $self = shift;

    my $dbh = $self->dbh;
    my $e   = $self->escape;
    my $sth = $dbh->prepare("SELECT ${e}id${e} FROM ipcm_clients ORDER BY ${e}id${e} ASC") or die $dbh->errstr;
    $sth->execute();

    return map { $_->[0] } @{$sth->fetchall_arrayref([0])};
}

sub client_pid {
    my $self = shift;
    my ($id) = @_;

    my $row = $self->_get_client($id) or return undef;
    return $row->{pid} // undef;
}

sub client_exists {
    my $self = shift;
    my ($id) = @_;
    return $self->_get_client($id) ? 1 : 0;
}

sub _get_client {
    my $self = shift;
    my ($id) = @_;

    my $dbh = $self->dbh;
    my $e   = $self->escape;
    my $sth = $dbh->prepare("SELECT * FROM ipcm_clients WHERE ${e}id${e} = ?") or die $dbh->errstr;
    $sth->execute($id);
    return $sth->fetchrow_hashref;
}

sub send_message {
    my $self = shift;
    my ($msg) = @_;

    my $dbh = $self->dbh;
    my $e   = $self->escape;
    my $sth = $dbh->prepare("INSERT INTO ipcm_messages(${e}id${e}, ${e}from${e}, ${e}to${e}, ${e}stamp${e}, ${e}broadcast${e}, ${e}content${e}) VALUES (?, ?, ?, ?, ?, ?)")
        or die $dbh->errstr;

    $sth->execute(
        @{$msg}{qw/id from to stamp/},
        ($msg->{broadcast} ? 1 : 0),
        $self->{+SERIALIZER}->serialize($msg->{content}),
    ) or die $dbh->errstr;
}

sub _get_message_ids {
    my $self = shift;
    my $dbh  = $self->dbh;
    my $e    = $self->escape;
    my $sth  = $dbh->prepare("SELECT ${e}id${e} FROM ipcm_messages WHERE ${e}to${e} = ? ORDER BY ${e}stamp${e} ASC") or die $dbh->errstr;
    $sth->execute($self->{+ID}) or die $dbh->errstr;
    my $ids = [map { $_->[0] } @{$sth->fetchall_arrayref([0])}];
    return $ids if $ids && @$ids;
    return;
}

sub get_messages {
    my $self = shift;
    my $dbh  = $self->dbh;

    my $ids = $self->_get_message_ids or return;

    my $e     = $self->escape;
    my $where = "FROM ipcm_messages WHERE ${e}id${e} IN (" . join(', ' => map { '?' } 1 .. scalar(@$ids)) . ")";
    my $sth   = $dbh->prepare("SELECT * $where") or die $dbh->errstr;
    $sth->execute(@$ids) or die $dbh->errstr;
    my $rows = $sth->fetchall_arrayref({});

    my @out;

    for my $row (@$rows) {
        $row->{content} = $self->{+SERIALIZER}->deserialize($row->{content});
        push @out => IPC::Manager::Message->new($row);
    }

    $sth = $dbh->prepare("DELETE $where") or die $dbh->errstr;
    $sth->execute(@$ids)                  or die $dbh->errstr;

    return @out;
}

sub requeue_message {
    my $self = shift;
    $self->send_message($_) for @_;
}

sub broadcast {
    my $self = shift;
    my ($msg) = @_;

    for my $client ($self->clients) {
        $self->send_message($msg->clone(to => $client, broadcast => 1));
    }
}

sub pre_disconnect_hook {
    my $self = shift;

    my $dbh = $self->dbh;
    my $sth = $dbh->prepare("DELETE FROM ipcm_clients WHERE id = ?") or die $dbh->errstr;
    $sth->execute($self->{+ID}) or die $dbh->errstr;
}

sub pre_suspend_hook {
    my $self = shift;

    my $dbh = $self->dbh;
    my $e   = $self->escape;
    my $sth = $dbh->prepare("UPDATE ipcm_clients SET ${e}pid${e} = NULL WHERE ${e}id${e} = ?") or die $dbh->errstr;
    $sth->execute($self->{+ID}) or die $dbh->errstr;
}

1;


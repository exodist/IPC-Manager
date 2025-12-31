package IPC::Manager::Base::DBI;
use strict;
use warnings;

use Carp qw/croak/;
use Scalar::Util qw/blessed/;
use File::Temp qw/tempfile/;
use IPC::Manager::Util qw/pid_is_running/;

use DBI;

use parent 'IPC::Manager::Client';
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

sub dbh {
    my $this = shift;
    my (%params) = @_;

    return $this->{+DBH} if blessed($this) && $this->{+DBH};

    my $dsn   = $params{dsn};
    my $user  = $params{user};
    my $pass  = $params{pass};
    my $attrs = $params{attrs};

    if (blessed($this)) {
        $this->pid_check;
        $dsn   //= $this->dsn;
        $user  //= $this->user;
        $pass  //= $this->pass;
        $attrs //= $this->attrs;
    }

    croak "No DSN" unless $dsn;
    $attrs //= {};

    my $dbh = DBI->connect($dsn, $user, $pass, $attrs) or die "Could not connect";

    $this->{+DBH} = $dbh if blessed($this);

    return $dbh;
}

sub init_db {
    my $this = shift;

    my $dbh = $this->dbh(@_);

    for my $sql ($this->table_sql) {
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

    if ($self->{+RECONNECT}) {
        my $row = $self->_get_peer($self->{+ID}) or die "The '$id' peer does not exist";

        if (my $pid = $row->{pid}) {
            croak "Looks like the connection is already running in pid $pid" if $pid && pid_is_running($pid);
        }
    }
    else {
        my $dbh = $self->dbh;
        my $e   = $self->escape;
        my $sth = $dbh->prepare("INSERT INTO ipcm_peers(${e}id${e}, ${e}pid${e}, ${e}active${e}) VALUES (?, ?, TRUE)") or die $dbh->errstr;
        $sth->execute($id, $self->{+PID}) or die $dbh->errstr;
    }
}

sub all_stats {
    my $self = shift;

    my $out = {};

    my $dbh = $self->dbh;
    my $e   = $self->escape;
    my $sth = $dbh->prepare("SELECT ${e}id${e}, ${e}stats${e} FROM ipcm_peers") or die $dbh->errstr;
    $sth->execute() or die $dbh->errstr;

    while (my $row = $sth->fetchrow_arrayref) {
        $out->{$row->[0]} = $self->{+SERIALIZER}->deserialize($row->[1]);
    }

    return $out;
}

sub write_stats {
    my $self = shift;

    my $dbh = $self->dbh;
    my $e   = $self->escape;
    my $sth = $dbh->prepare("UPDATE ipcm_peers SET ${e}stats${e} = ? WHERE ${e}id${e} = ?") or die $dbh->errstr;
    $sth->execute($self->{+SERIALIZER}->serialize($self->{+STATS}), $self->{+ID}) or die $dbh->errstr;
}

sub read_stats {
    my $self = shift;

    my $dbh = $self->dbh;
    my $e   = $self->escape;
    my $sth = $dbh->prepare("SELECT ${e}stats${e} FROM ipcm_peers WHERE ${e}id${e} = ?") or die $dbh->errstr;
    $sth->execute($self->{+ID}) or die $dbh->errstr;

    my $row = $sth->fetchrow_arrayref or return undef;
    return $self->{+SERIALIZER}->deserialize($row->[0]);
}

sub peers {
    my $self = shift;

    my $dbh = $self->dbh;
    my $e   = $self->escape;
    my $sth = $dbh->prepare("SELECT ${e}id${e} FROM ipcm_peers WHERE ${e}id${e} != ? ORDER BY ${e}id${e} ASC") or die $dbh->errstr;
    $sth->execute($self->{+ID});

    return map { $_->[0] } @{$sth->fetchall_arrayref([0])};
}

sub peer_pid {
    my $self = shift;
    my ($id) = @_;

    my $row = $self->_get_peer($id) or return undef;
    return $row->{pid} // undef;
}

sub peer_exists {
    my $self = shift;
    my ($id) = @_;
    return $self->_get_peer($id) ? 1 : 0;
}

sub _get_peer {
    my $self = shift;
    my ($id) = @_;

    my $dbh = $self->dbh;
    my $e   = $self->escape;
    my $sth = $dbh->prepare("SELECT * FROM ipcm_peers WHERE ${e}id${e} = ?") or die $dbh->errstr;
    $sth->execute($id);
    return $sth->fetchrow_hashref;
}

sub send_message {
    my $self = shift;
    my $msg = $self->build_message(@_);

    my $dbh = $self->dbh;
    my $e   = $self->escape;
    my $sth = $dbh->prepare("INSERT INTO ipcm_messages(${e}id${e}, ${e}from${e}, ${e}to${e}, ${e}stamp${e}, ${e}broadcast${e}, ${e}content${e}) VALUES (?, ?, ?, ?, ?, ?)")
        or die $dbh->errstr;

    $sth->execute(
        @{$msg}{qw/id from to stamp/},
        ($msg->{broadcast} ? 1 : 0),
        $self->{+SERIALIZER}->serialize($msg->{content}),
    ) or die $dbh->errstr;

    $self->{+STATS}->{sent}->{$msg->{to}}++;
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
        $self->{+STATS}->{read}->{$row->{from}}++;
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

sub pre_disconnect_hook {
    my $self = shift;

    my $dbh = $self->dbh;
    my $e   = $self->escape;
    my $sth = $dbh->prepare("UPDATE ipcm_peers SET ${e}pid${e} = NULL, active = FALSE WHERE ${e}id${e} = ?") or die $dbh->errstr;
    $sth->execute($self->{+ID}) or die $dbh->errstr;
}

sub pre_suspend_hook {
    my $self = shift;

    my $dbh = $self->dbh;
    my $e   = $self->escape;
    my $sth = $dbh->prepare("UPDATE ipcm_peers SET ${e}pid${e} = NULL WHERE ${e}id${e} = ?") or die $dbh->errstr;
    $sth->execute($self->{+ID}) or die $dbh->errstr;
}

1;


package IPC::Manager::Protocol::DBI::MariaDB;
use strict;
use warnings;

use Carp qw/croak/;
use File::Temp qw/tempdir/;
use IPC::Manager::Util qw/pid_is_running/;

use DBI;

use parent 'IPC::Manager::Protocol::DBI';
use Object::HashBase qw{
    +QDB
};

sub ready { 1 }

sub dsn { $_[0]->{+INFO} }

sub escape { '`' }

sub default_attrs { +{ AutoCommit => 1 } }

sub table_sql {
    return (
        <<"        EOT",
            CREATE TABLE IF NOT EXISTS ipcm_clients(
                `id`        VARCHAR(36)     NOT NULL PRIMARY KEY,
                `pid`       INTEGER         NOT NULL
            );
        EOT
        <<"        EOT",
            CREATE TABLE IF NOT EXISTS ipcm_messages(
                `id`        UUID            NOT NULL PRIMARY KEY,
                `to`        VARCHAR(36)     NOT NULL REFERENCES ipcm_clients(id) ON DELETE CASCADE,
                `from`      VARCHAR(36)     NOT NULL,
                `stamp`     DOUBLE          NOT NULL,
                `content`   BLOB            NOT NULL,
                `broadcast` BOOL            NOT NULL DEFAULT FALSE
            );
        EOT
    );
}

sub listen {
    my $class = shift;
    my (%params) = @_;

    my $dsn = $params{info};

    unless ($dsn) {
        require DBIx::QuickDB;
        my $qdb = DBIx::QuickDB->build_db(m_db => {driver => 'MariaDB'});
        $params{+QDB}  = $qdb;
        $params{+INFO} = $qdb->connect_string;
        $params{+USER} = $qdb->username;
        $params{+PASS} = $qdb->password;
    }

    $class->new(%params, ID() => 'manager', IS_MANAGER() => 1, MANAGER_PID() => $$);
}

sub manager_cleanup_hook {
    my $self = shift;
    delete $self->{+QDB};
}

1;

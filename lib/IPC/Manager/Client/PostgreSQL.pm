package IPC::Manager::Client::PostgreSQL;
use strict;
use warnings;

use Carp qw/croak/;
use File::Temp qw/tempdir/;
use IPC::Manager::Util qw/pid_is_running/;

use DBI;
use DBD::Pg;

use parent 'IPC::Manager::Base::DBI';
use Object::HashBase qw{
    +QDB
};

sub escape { '"' }

sub dsn { $_[0]->{+ROUTE} }

sub table_sql {
    return (
        <<"        EOT",
            CREATE TABLE IF NOT EXISTS ipcm_peers(
                "id"        VARCHAR(36)     NOT NULL PRIMARY KEY,
                "pid"       INTEGER         DEFAULT NULL,
                "active"    BOOL            NOT NULL DEFAULT TRUE,
                "stats"     BYTEA           DEFAULT NULL
            );
        EOT
        <<"        EOT",
            CREATE TABLE IF NOT EXISTS ipcm_messages(
                "id"        UUID            NOT NULL PRIMARY KEY,
                "to"        VARCHAR(36)     NOT NULL REFERENCES ipcm_peers(id) ON DELETE CASCADE,
                "from"      VARCHAR(36)     NOT NULL REFERENCES ipcm_peers(id) ON DELETE CASCADE,
                "stamp"     NUMERIC         NOT NULL,
                "content"   BYTEA           NOT NULL,
                "broadcast" BOOL            NOT NULL DEFAULT FALSE
            );
        EOT
    );
}

sub default_attrs { +{ AutoCommit => 1 } }

sub spawn {
    my $class = shift;
    my (%params) = @_;

    my $dsn = $params{route};

    unless ($dsn) {
        require DBIx::QuickDB;
        my $qdb = DBIx::QuickDB->build_db(pg_db => {driver => 'PostgreSQL'});
        $params{+QDB}  = $qdb;
        $params{+ROUTE} = $qdb->connect_string;
        $params{+USER} = $qdb->username;
        $params{+PASS} = $qdb->password;

        $dsn = $params{+ROUTE};
    }

    $class->init_db(%params, dsn => $dsn);

    return ($dsn, $params{+QDB});
}

sub unspawn {
    my $self = shift;
    my ($route, $stash) = @_;

    undef($stash);
}

1;

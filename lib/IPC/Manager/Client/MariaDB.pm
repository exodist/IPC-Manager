package IPC::Manager::Client::MariaDB;
use strict;
use warnings;

use Carp qw/croak/;
use File::Temp qw/tempdir/;
use IPC::Manager::Util qw/pid_is_running/;

use DBI;

use parent 'IPC::Manager::Base::DBI';
use Object::HashBase qw{
    +QDB
};

sub dsn { $_[0]->{+INFO} }

sub escape { '`' }

sub default_attrs { +{ AutoCommit => 1 } }

sub table_sql {
    return (
        <<"        EOT",
            CREATE TABLE IF NOT EXISTS ipcm_peers(
                `id`        VARCHAR(36)     NOT NULL PRIMARY KEY,
                `pid`       INTEGER         DEFAULT NULL,
                `active`    BOOL            NOT NULL DEFAULT TRUE,
                `stats`     BLOB            DEFAULT NULL
            );
        EOT
        <<"        EOT",
            CREATE TABLE IF NOT EXISTS ipcm_messages(
                `id`        UUID            NOT NULL PRIMARY KEY,
                `to`        VARCHAR(36)     NOT NULL REFERENCES ipcm_peers(id) ON DELETE CASCADE,
                `from`      VARCHAR(36)     NOT NULL REFERENCES ipcm_peers(id) ON DELETE CASCADE,
                `stamp`     DOUBLE          NOT NULL,
                `content`   BLOB            NOT NULL,
                `broadcast` BOOL            NOT NULL DEFAULT FALSE
            );
        EOT
    );
}

sub vivify_info {
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

        $dsn = $params{+INFO};
    }

    $class->init_db(%params, dsn => $dsn);

    return ($dsn, $params{+QDB});
}

sub unspawn {
    my $self = shift;
    my ($info, $stash) = @_;

    undef($stash);
}

1;

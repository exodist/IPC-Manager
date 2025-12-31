package IPC::Manager::Client::SQLite;
use strict;
use warnings;

use Carp qw/croak/;
use File::Temp qw/tempfile/;
use IPC::Manager::Util qw/pid_is_running/;

use DBI;

use parent 'IPC::Manager::Base::DBI';
use Object::HashBase;

sub dsn { "dbi:SQLite:dbname=" . (@_ > 1 ? $_[1] : $_[0]->{+ROUTE}) }

sub escape { '`' }

sub table_sql {
    return (
        <<"        EOT",
            CREATE TABLE IF NOT EXISTS ipcm_peers(
                `id`        CHAR(36)        NOT NULL PRIMARY KEY,
                `pid`       INTEGER         DEFAULT NULL,
                `active`    BOOL            NOT NULL DEFAULT TRUE,
                `stats`     BLOB            DEFAULT NULL
            );
        EOT
        <<"        EOT",
            CREATE TABLE IF NOT EXISTS ipcm_messages(
                `id`        UUID            NOT NULL PRIMARY KEY,
                `to`        CHAR(36)        NOT NULL REFERENCES ipcm_peers(id) ON DELETE CASCADE,
                `from`      CHAR(36)        NOT NULL REFERENCES ipcm_peers(id) ON DELETE CASCADE,
                `stamp`     BIGINT          NOT NULL,
                `content`   BLOB            NOT NULL,
                `broadcast` BOOL            NOT NULL DEFAULT FALSE
            );
        EOT
    );
}

sub spawn {
    my $class = shift;
    my (%params) = @_;

    my $dbfile = delete $params{route};
    unless ($dbfile) {
        my $template = delete $params{template} // "PerlIPCManager-$$-XXXXXX";
        my ($fh, $file) = tempfile($template, TMPDIR => 1, CLEANUP => 0, SUFFIX => '.sqlite', EXLOCK => 0);
        $dbfile = $file;
    }

    $params{dsn} //= $class->dsn($dbfile);

    $class->init_db(%params);

    return "$dbfile";
}

sub unspawn {
    my $class = shift;
    my ($route) = @_;
    unlink($route);
}

1;

package IPC::Manager::Protocol::DBI::SQLite;
use strict;
use warnings;

use Carp qw/croak/;
use File::Temp qw/tempfile/;
use IPC::Manager::Util qw/pid_is_running/;

use DBI;
use DBD::SQLite;

use parent 'IPC::Manager::Protocol::DBI';
use Object::HashBase;

sub ready { -f $_[0]->{+INFO} }
sub dsn { "dbi:SQLite:dbname=$_[0]->{+INFO}" }

sub escape { '`' }

sub table_sql {
    return (
        <<"        EOT",
            CREATE TABLE IF NOT EXISTS ipcm_clients(
                `id`        CHAR(36)        NOT NULL PRIMARY KEY,
                `pid`       INTEGER         NOT NULL
            );
        EOT
        <<"        EOT",
            CREATE TABLE IF NOT EXISTS ipcm_messages(
                `id`        UUID            NOT NULL,
                `to`        CHAR(36)        NOT NULL REFERENCES ipcm_clients(id) ON DELETE CASCADE,
                `from`      CHAR(36)        NOT NULL,
                `stamp`     BIGINT          NOT NULL,
                `content`   BLOB            NOT NULL,
                `broadcast` BOOL            NOT NULL DEFAULT FALSE,
                PRIMARY KEY(`id`, `to`)
            );
        EOT
    );
}

sub listen {
    my $class = shift;
    my (%params) = @_;

    my $dbfile = $params{info};
    unless ($dbfile) {
        my $template = $params{template} // "PerlIPCManager-$$-XXXXXX";
        my ($fh, $file) = tempfile($template, TMPDIR => 1, CLEANUP => 0, SUFFIX => '.sqlite', EXLOCK => 0);
        $dbfile = $file;
    }

    $class->new(%params, INFO() => $dbfile, ID() => 'manager', IS_MANAGER() => 1, MANAGER_PID() => $$);
}

sub manager_cleanup_hook {
    my $self = shift;
    unlink($self->{+INFO});
}

1;

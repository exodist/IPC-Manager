package IPC::Manager::Util;
use strict;
use warnings;

our $VERSION = '0.000001';

use Carp qw/confess/;
use Errno qw/ESRCH/;
use Importer Importer => 'import';

our @EXPORT_OK = qw{
    pid_is_running
};

sub pid_is_running {
    my ($pid) = @_;

    confess "A pid is required" unless $pid;

    local $!;

    return 1 if kill(0, $pid);    # Running and we have perms
    return 0 if $! == ESRCH;      # Does not exist (not running)
    return -1;                    # Running, but not ours
}

1;

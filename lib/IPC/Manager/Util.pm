package IPC::Manager::Util;
use strict;
use warnings;

use Carp qw/croak/;
use Errno qw/ESRCH/;

BEGIN {
    if (eval { require IO::Select; 1 }) {
        *USE_IO_SELECT = sub() { 1 };
    }
    else {
        *USE_IO_SELECT = sub() { 0 };
    }

    if (eval { require Linux::Inotify2; Linux::Inotify2->can('fh') ? 1 : 0 }) {
        *USE_INOTIFY = sub() { 1 };
    }
    else {
        *USE_INOTIFY = sub() { 0 };
    }
}

use Importer Importer => 'import';

our @EXPORT_OK = qw{
    USE_INOTIFY
    USE_IO_SELECT
    require_mod
    pid_is_running
};

sub require_mod {
    my $mod = shift;

    my $file = $mod;
    $file =~ s{::}{/}g;
    $file .= ".pm";

    require($file);

    return $mod;
}

sub pid_is_running {
    my $pid = pop;

    croak "A pid is required" unless $pid;

    local $!;

    return 1 if kill(0, $pid);    # Running and we have perms
    return 0 if $! == ESRCH;      # Does not exist (not running)
    return -1;                    # Running, but not ours
}

1;

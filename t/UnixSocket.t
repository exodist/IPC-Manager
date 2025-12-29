use strict;
use warnings;

{
    no warnings 'once';
    $main::PROTOCOL = 'UnixSocket';
}

do './t/generic_test.pl' or die $@;

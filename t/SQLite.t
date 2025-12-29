use strict;
use warnings;

{
    no warnings 'once';
    $main::PROTOCOL = 'SQLite';
}

do './t/generic_test.pl' or die $@;

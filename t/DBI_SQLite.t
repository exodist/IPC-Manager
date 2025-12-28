use strict;
use warnings;

{
    no warnings 'once';
    $main::PROTOCOL = 'DBI::SQLite';
}

do './t/generic_test.pl' or die $@;

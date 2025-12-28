use strict;
use warnings;

{
    no warnings 'once';
    $main::PROTOCOL = 'DBI::MySQL';
}

do './t/generic_test.pl' or die $@;

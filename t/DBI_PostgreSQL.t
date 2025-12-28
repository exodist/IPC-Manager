use strict;
use warnings;

{
    no warnings 'once';
    $main::PROTOCOL = 'DBI::PostgreSQL';
}

do './t/generic_test.pl' or die $@;

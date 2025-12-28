use strict;
use warnings;

{
    no warnings 'once';
    $main::PROTOCOL = 'DBI::MariaDB';
}

do './t/generic_test.pl' or die $@;

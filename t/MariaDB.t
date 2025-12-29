use strict;
use warnings;

{
    no warnings 'once';
    $main::PROTOCOL = 'MariaDB';
}

do './t/generic_test.pl' or die $@;

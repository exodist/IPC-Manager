use strict;
use warnings;

{
    no warnings 'once';
    $main::PROTOCOL = 'MySQL';
}

do './t/generic_test.pl' or die $@;

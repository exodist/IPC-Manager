use strict;
use warnings;

{
    no warnings 'once';
    $main::PROTOCOL = 'FS::MessageFiles';
}

do './t/generic_test.pl' or die $@;

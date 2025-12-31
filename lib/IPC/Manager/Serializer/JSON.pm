package IPC::Manager::Serializer::JSON;
use strict;
use warnings;

our $VERSION = '0.000001';

use parent 'IPC::Manager::Serializer';

BEGIN {
    local $@;
    my $class;
    $class //= eval { require Cpanel::JSON::XS; 'Cpanel::JSON::XS' };
    $class //= eval { require JSON::XS;         'JSON::XS' };
    $class //= eval { require JSON::PP;         'JSON::PP' };

    die "Could not find 'Cpanel::JSON::XS', 'JSON::XS', or 'JSON::PP'" unless $class;

    my $json = $class->new->ascii(1)->convert_blessed(1)->allow_nonref(1);

    *JSON = sub() { $json };
}

sub serialize   { JSON()->encode($_[1]) }
sub deserialize { JSON()->decode($_[1]) }

1;

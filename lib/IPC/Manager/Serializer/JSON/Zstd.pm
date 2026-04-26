package IPC::Manager::Serializer::JSON::Zstd;
use strict;
use warnings;

our $VERSION = '0.000034';

use parent 'IPC::Manager::Serializer::JSON';

use Carp qw/croak/;

my $HAVE_ZSTD;

sub _have_zstd {
    return $HAVE_ZSTD if defined $HAVE_ZSTD;
    return $HAVE_ZSTD = eval { require Compress::Zstd; Compress::Zstd->VERSION('0.20'); 1 } ? 1 : 0;
}

sub viable { _have_zstd() }

sub serialize {
    my ($class, $obj) = @_;
    croak "Compress::Zstd 0.20 or newer is required for IPC::Manager::Serializer::JSON::Zstd"
        unless _have_zstd();
    my $json = $class->SUPER::serialize($obj);
    return Compress::Zstd::compress($json);
}

sub deserialize {
    my ($class, $bytes) = @_;
    croak "Compress::Zstd 0.20 or newer is required for IPC::Manager::Serializer::JSON::Zstd"
        unless _have_zstd();
    my $json = Compress::Zstd::decompress($bytes);
    croak "Failed to decompress zstd payload" unless defined $json;
    return $class->SUPER::deserialize($json);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

IPC::Manager::Serializer::JSON::Zstd - JSON serializer with zstd compression for IPC::Manager.

=head1 DESCRIPTION

Subclass of L<IPC::Manager::Serializer::JSON> that compresses serialized
payloads with L<Compress::Zstd> before sending them and decompresses them on
receipt. JSON encoding/decoding is delegated to the parent class; only the
on-the-wire bytes are different.

When L<Compress::Zstd> 0.20 or newer is installed C<JSON::Zstd> is selected as
the default serializer for L<IPC::Manager>. If C<Compress::Zstd> is missing or
older, IPC::Manager falls back to L<IPC::Manager::Serializer::JSON>.

=head1 SYNOPSIS

    use IPC::Manager;

    my $ipcm = ipcm_spawn(serializer => 'JSON::Zstd');

    my $con = IPC::Manager::Client::PROTOCOL->connect($id, 'JSON::Zstd');

=head1 METHODS

=over 4

=item $bool = IPC::Manager::Serializer::JSON::Zstd->viable

Returns true when L<Compress::Zstd> 0.20 or newer is loadable, false
otherwise.

=item $bytes = IPC::Manager::Serializer::JSON::Zstd->serialize($obj)

JSON-encode C<$obj> and zstd-compress the result. Croaks if
L<Compress::Zstd> is not available.

=item $obj = IPC::Manager::Serializer::JSON::Zstd->deserialize($bytes)

Zstd-decompress C<$bytes> and JSON-decode the result. Croaks if
L<Compress::Zstd> is not available, or if decompression fails.

=back

=head1 SOURCE

The source code repository for IPC::Manager can be found at
L<https://github.com/exodist/IPC-Manager>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<https://dev.perl.org/licenses/>

=cut

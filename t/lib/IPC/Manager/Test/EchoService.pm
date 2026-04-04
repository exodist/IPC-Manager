package IPC::Manager::Test::EchoService;
use strict;
use warnings;

our $VERSION = '0.000011';

use Object::HashBase qw{
    <name
    <orig_io
    <ipcm_info
    <redirect

    use_posix_exit
    intercept_errors
    watch_pids
};

use Role::Tiny::With;

sub pid     { $_[0]->{pid} }
sub set_pid { $_[0]->{pid} = $_[1] }

sub handle_request {
    my ($self, $req, $msg) = @_;
    return "echo: $req->{request}";
}

with 'IPC::Manager::Role::Service';

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

IPC::Manager::Test::EchoService - Minimal service for testing the exec code path

=head1 DESCRIPTION

A simple service that echoes back request content.  It exists as an on-disk
module so that L<IPC::Manager::Service::State>'s C<exec> code path can load it
in the newly exec'd process.

=head1 SOURCE

The source code repository for IPC::Manager can be found at
L<https://github.com/exodist/IPC-Manager>.

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<https://dev.perl.org/licenses/>

=cut

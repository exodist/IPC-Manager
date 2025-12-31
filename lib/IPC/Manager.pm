package IPC::Manager;
use strict;
use warnings;

use Carp qw/croak/;

use IPC::Manager::Spawn();
use IPC::Manager::Serializer::JSON();

use Importer Importer => 'import';

our @EXPORT_OK = qw/ipcm_connect ipcm_reconnect ipcm_spawn ipcm/;

sub ipcm()         { __PACKAGE__ }
sub connect        { shift; ipcm_connect(@_) }
sub reconnect      { shift; ipcm_reconnect(@_) }
sub spawn          { shift; ipcm_spawn(@_) }
sub ipcm_connect   { _connect(connect   => @_) }
sub ipcm_reconnect { _connect(reconnect => @_) }

sub _parse_cinfo {
    my $cinfo = shift;

    my ($protocol, $route, $serializer);

    my $rtype = ref $cinfo;
    if ($rtype eq 'ARRAY') {
        ($protocol, $serializer, $route) = @$cinfo;
    }
    elsif (!$rtype) {
        ($protocol, $serializer, $route) = @{IPC::Manager::Serializer::JSON->deserialize($cinfo)};
        $protocol   = _parse_protocol($protocol);
        $serializer = _parse_serializer($serializer);
    }
    else {
        croak "Not sure what to do with $cinfo";
    }

    _require_mod($protocol);
    _require_mod($serializer);

    return ($protocol, $serializer, $route);
}

sub _parse_protocol {
    my $protocol = shift;
    $protocol = "IPC::Manager::Client::$protocol" unless $protocol =~ s/^\+// || $protocol =~ m/^IPC::Manager::Client::/;
    return $protocol;
}

sub _parse_serializer {
    my $serializer = shift;
    $serializer = "IPC::Manager::Serializer::$serializer" unless $serializer =~ s/^\+// || $serializer =~ m/^IPC::Manager::Serializer::/;
    return $serializer;
}

sub _connect {
    my ($meth, $id, $cinfo, %params) = @_;

    my ($protocol, $serializer, $route) = _parse_cinfo($cinfo);

    return $protocol->$meth($id, $serializer, $route, %params);
}

sub _require_mod {
    my $mod = shift;

    my $file = $mod;
    $file =~ s{::}{/}g;
    $file .= ".pm";

    require($file);
}

sub ipcm_spawn {
    my %params = @_;

    my $guard      = delete $params{guard}      // 1;
    my $serializer = delete $params{serializer} // 'JSON';
    my $protocol   = delete $params{protocol};
    my $protocols  = delete $params{procotols} // [
        'PostgreSQL',
        'MariaDB',
        'MySQL',
        'SQLite',
        'UnixSocket',
        'AtomicPipe',
        'MessageFiles',
    ];

    if ($protocol) {
        $protocol = _parse_protocol($protocol);
        _require_mod($protocol);
    }
    else {
        for my $prot (@$protocols) {
            $prot = _parse_protocol($prot);

            local $@;
            eval { _require_mod($prot); $prot->viable } or next;

            $protocol = $prot;
            last;
        }
    }

    $serializer = _parse_serializer($serializer);
    _require_mod($serializer);

    my ($route, $stash) = $protocol->spawn(%params, serializer => $serializer);

    return IPC::Manager::Spawn->new(
        protocol   => $protocol,
        serializer => $serializer,
        route      => $route,
        stash      => $stash,
        guard      => $guard,
    );
}

1;

package IPC::Manager;
use strict;
use warnings;

use Carp qw/croak/;

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

    my ($protocol, $info);

    my $rtype = ref $cinfo;
    if ($rtype eq 'ARRAY') {
        ($protocol, $info) = @$cinfo;
    }
    elsif(!$rtype) {
        ($protocol, $info) = split /\|/, $cinfo;
        $protocol = _parse_protocol($protocol);
    }
    else {
        croak "Not sure what to do with $cinfo";
    }

    return ($protocol, $info);
}

sub _parse_protocol {
    my $protocol = shift;

    $protocol = "IPC::Manager::Client::$protocol" unless $protocol =~ s/^\+// || $protocol =~ m/^IPC::Manager::Client::/;

    return $protocol;
}

sub _connect {
    my ($meth, $id, $cinfo, %params) = @_;

    my ($protocol, $info) = _parse_cinfo($cinfo);

    return $protocol->$meth($id, $info, %params);
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

    my $guard     = delete $params{guard} // 1;
    my $protocol  = delete $params{protocol};
    my $protocols = delete $params{procotols} // [
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

    croak "No viable protocol found" unless $protocol;

    return $protocol->spawn(%params, guard => $guard);
}

1;

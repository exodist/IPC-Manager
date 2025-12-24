package IPC::Manager::Client;
use strict;
use warnings;

use IPC::Manager::Message;
use Scalar::Util qw/weaken blessed/;

use Carp qw/croak/;

use Object::HashBase qw{
    <protocol
    <pid
};

my ($CLIENT_PID, %CLIENTS);

sub disconnect_local_clients {
    my $class = shift;

    my ($protocol, $info) = @_;
    return unless $CLIENT_PID && $CLIENT_PID == $$;

    my $clients = delete $CLIENTS{$protocol}{$info} or return;

    $_->disconnect for grep { $_ } values %$clients;

    return;
}

# Delegate
sub AUTOLOAD {
    my $self = shift;
    my $class = blessed($self) // $self;
    our $AUTOLOAD;
    my $meth = $AUTOLOAD;
    $meth =~ s/^.+\:://g;

    if ($self->pid_check) {
        if (my $inst = $self->{+PROTOCOL}) {
            if (my $sub = $inst->can($meth)) {
                unshift @_ => $inst;
                goto &$sub;
            }
        }
    }

    croak qq{Can't locate object method "$meth" via package "$class"};
}

sub _connect {
    my $class = shift;
    my ($meth, $cinfo, $id, $pid) = @_;

    croak "The first argument must be a connection info string or arrayref" unless $cinfo;
    croak "The second argument must be a connection ID" unless $id;
    $pid //= $$;

    my $rtype = ref $cinfo;
    my ($protocol, $info);
    if ($rtype eq 'ARRAY') {
        ($protocol, $info) = @$cinfo;
    }
    elsif(!$rtype) {
        ($protocol, $info) = split /\|/, $cinfo;
        $protocol = "IPC::Manager::Protocol::$protocol" unless $protocol =~ s/^\+// || $protocol =~ m/^IPC::Manager::Protocol::/;
    }

    my $inst = $protocol->$meth($info, $pid, $id);

    my $out = $class->new(protocol => $inst, pid => $pid);

    unless ($CLIENT_PID && $CLIENT_PID == $$) {
        $CLIENT_PID = $$;
        %CLIENTS = ();
    }

    weaken($CLIENTS{$protocol}{$info}{$id} = $out);

    return $out;
}

sub connect {
    my $class = shift;
    $class->_connect('connect', @_);
}

sub reconnect {
    my $class = shift;
    $class->_connect('reconnect', @_);
}

sub send_message {
    my $self = shift;
    my ($to, $content, $id) = @_;

    $self->pid_check;

    my $msg = IPC::Manager::Message->new(
        from    => $self->{+PROTOCOL}->id,
        to      => $to,
        stamp   => time,
        content => $content,
        $id ? (id => $id) : (),
    );

    $self->{+PROTOCOL}->send_message($msg);
    return $msg;
}

sub broadcast {
    my $self = shift;
    my ($content, $id) = @_;

    $self->pid_check;

    my $msg = IPC::Manager::Message->new(
        from      => $self->{+PROTOCOL}->id,
        broadcast => 1,
        stamp     => time,
        content   => $content,
        $id ? (id => $id) : (),
    );

    $self->{+PROTOCOL}->broadcast($msg);
    return $msg;
}

sub pid_check {
    croak "Client used from wrong PID" if $_[0]->{+PID} != $$;
    return $_[0];
}

sub DESTROY {
    my $self = shift;
    return if $self->{+PID} != $$;
    my $prot = $self->{+PROTOCOL};
    delete $CLIENTS{blessed($prot)}{$prot->info}{$self->id};
}

1;

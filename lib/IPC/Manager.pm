package IPC::Manager;
use strict;
use warnings;

use Carp qw/croak/;
use Time::HiRes qw/sleep time/;
use Scalar::Util qw/blessed/;
use Test2::Util::UUID qw/gen_uuid/;

use Scope::Guard();
use POSIX();

use Object::HashBase qw{
    <protocol
    <prot_inst
    +prot_info
    <pid
    +handle_message
};

sub init {
    my $self = shift;

    croak "'protocol' is a required attribute"
        unless $self->{+PROTOCOL};

    croak "'handle_message' is a required attribute"
        unless $self->{+HANDLE_MESSAGE};

    $self->{+PROTOCOL} = $self->resolve_protocol($self->{+PROTOCOL});
}

sub _resolve_protocol_package {
    my $class = shift;
    my ($prot) = @_;

    return $prot if $prot =~ m/^IPC::Manager::Protocol::/;
    return $1 if $prot =~ m/^\+(.+)$/;
    return "IPC::Manager::Protocol::$prot";
}

sub resolve_protocol {
    my $class = shift;
    my ($prot) = @_;

    my $pkg = $class->_resolve_protocol_package($prot);
    my $file = $pkg;
    $file =~ s{::}{/}g;
    $file .= ".pm";
    require($file);

    return $pkg;
}

sub prot_info {
    my $self = shift;

    return $self->{+PROT_INFO} if $self->{+PROT_INFO};

    my $inst = $self->{+PROT_INST} or croak "Not Started";
    return $self->{+PROT_INFO} = $inst->info;
}

sub connect_string {
    my $self = shift;
    my $info = $self->prot_info;
    my $prot = $self->{+PROTOCOL};

    if ($prot =~ m/^IPC::Manager::Protocol::(.+)$/) {
        $prot = $1;
    }
    else {
        $prot = "+$prot";
    }

    return "${prot}|${info}";
}

sub started {
    my $self = shift;
    return 1 if $self->{+PID};
    return 1 if $self->{+PROT_INST};
    return 0;
}

sub start {
    my $self = shift;

    $self->{+PID}       = $$;
    $self->{+PROT_INST} = $self->{+PROTOCOL}->listen(@_);
    $self->{+PROT_INFO} = $self->{+PROT_INST}->info;

    return $self->{+PROT_INFO};
}

sub start_loop {
    my $self = shift;
    my ($cb) = @_;

    local ($self->{+PID}, $self->{+PROT_INST}, $self->{+PROT_INFO});
    $self->start;

    my $inst = $self->{+PROT_INST};

    $self->iterate($cb) while $inst->ready();

    $inst->terminate;
}

sub iterate {
    my $self = shift;
    my ($cb) = @_;

    my $inst    = $self->{+PROT_INST} or croak "Not Started";
    my $handler = $self->{+HANDLE_MESSAGE};

    $inst->iterate();
    $cb->() if $cb;

    for my $msg ($inst->get_messages('manager')) {
        $self->$handler($msg);
    }
}

sub send_message {
    my $self = shift;
    my ($to, $content) = @_;

    my $msg = IPC::Manager::Message->new(
        from    => $self->{+PROT_INST}->id,
        to      => $to,
        stamp   => time,
        content => $content,
    );

    $self->{+PROT_INST}->send_message($msg);
    return $msg;
}


sub spawn {
    my $self = shift;
    my ($cb, %params) = @_;

    my $inst = $self->{+PROTOCOL}->spawn(%params);
    $self->{+PROT_INFO} = $inst->info;

    my $parent = $$;
    my $pid = fork // die "could not fork: $!";

    if ($pid) {
        $inst->post_fork_parent($pid);
        $self->{+PID} = $pid;
        return $self->{+PROT_INFO};
    }

    require IPC::Manager::Client;

    $inst->post_fork_child($parent);

    $self->{+PID}       = $$;
    $self->{+PROT_INST} = $inst;

    my $guard = Scope::Guard->new(sub { print STDERR "Scope Leak!\n"; POSIX::_exit(1) });

    my $handler = sub {
        $inst->terminate;
        $inst->DESTROY;
        POSIX::_exit(0);
    };

    $SIG{INT} = $handler;
    $SIG{TERM} = $handler;
    $SIG{PIPE} = 'IGNORE';

    my $try = sub {
        my ($run) = @_;
        my $out;
        local $@;
        my $start = time;
        if (eval { $out = $run->(); 1 }) {
            my $delta = time - $start;
            sleep(0.02 - $delta) if $delta < 0.02;
            return $out;
        }
        warn $@;
        sleep 1;
        return 0;
    };

    my $stop;
    my $ready   = sub { $inst->ready };
    my $iterate = sub { $self->iterate($cb) };

    $try->($iterate) while $try->($ready);

    POSIX::_exit(255);
}

sub spawn_and_connect {
    my $self = shift;
    my ($id) = @_;

    $self->spawn;
    return $self->connect($id);
}

sub connect {
    my $self = shift;
    my ($id) = @_;

    my $info = $self->{+PROT_INFO} or croak "No connection info, did you start the manager";

    require IPC::Manager::Client;
    return IPC::Manager::Client->connect([$self->{+PROTOCOL}, $info], $id, $$);
}

sub reconnect {
    my $self = shift;
    my ($id) = @_;

    my $info = $self->{+PROT_INFO} or croak "No connection info, did you start the manager";

    require IPC::Manager::Client;
    return IPC::Manager::Client->reconnect([$self->{+PROTOCOL}, $info], $id, $$);
}

sub stop {
    my $self = shift;
    my ($signal) = @_;
    $signal //= 'TERM';

    my $pid  = delete $self->{+PID};
    my $inst = delete $self->{+PROT_INST};
    my $info = delete $self->{+PROT_INFO};

    if ($pid && $pid != $$) {
        kill($signal, $pid);
        local $? = 0;
        my $check = waitpid($pid, 0);

        croak "waitpid() did not return a valid result (got $check, expected $pid)" unless $check && $check == $pid;
        croak "Manager process did not exit cleanly ($?)" if $?;
    }
    elsif($inst) {
        $inst->terminate();
    }
    else {
        croak "Not Started or Spawned";
    }

    return;
}

sub DESTROY {
    my $self = shift;
    return unless $self->started;
    return unless $self->{+PID} == $$;

    $self->stop;
}

sub AUTOLOAD {
    my $self = shift;
    my $class = blessed($self) // $self;
    our $AUTOLOAD;
    my $meth = $AUTOLOAD;
    $meth =~ s/^.+\:://g;

    if ($self->{+PID} == $$) {
        if (my $inst = $self->{+PROT_INST}) {
            if (my $sub = $inst->can($meth)) {
                unshift @_ => $inst;
                goto &$sub;
            }
        }
    }

    croak qq{Can't locate object method "$meth" via package "$class"};
}

1;

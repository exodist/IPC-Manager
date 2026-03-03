package IPC::Manager::Coordinator::Process::This;
use strict;
use warnings;

use Carp qw/croak/;
use Sub::Util qw/set_subname/;
use List::Util qw/any/;
use Time::HiRes qw/time sleep/;
use Scalar::Util qw/refaddr/;

use IPC::Manager::Util qw/pid_is_running/;

use parent 'IPC::Manager::Coordinator::Process';
use Object::HashBase qw{
    <pid

    interval
    <last_interval

    <orig_sig

    <on_start
    <on_cleanup
    <on_message
    <on_request_message
    <on_general_message
    <on_interval
    <on_peer_delta
    <on_all

    <intercept_errors

    +on_sig
    +should_end
    <terminated

    +select

    +peers

    watch_pids
};

my @ACTIONS = qw{
    cleanup
    message
    request_message
    general_message
    interval
    peer_delta
    all
    should_end
};

sub handle_request {}

sub init {
    my $self = shift;

    $self->SUPER::init();

    delete $self->{+TERMINATED};

    # Keep an actual one passed in, but otherwise make sure this does not exist.
    delete $self->{+SELECT} unless defined $self->{+SELECT};

    $self->{+WATCH_PIDS}      //= [];

    for my $action (@ACTIONS) {
        my $set = delete $self->{"on_$action"};
        $set = [$set] unless ref($set) eq 'ARRAY';
        $self->{"on_$action"} = $set;
    }

    my $on_sig;
    for my $key (keys %$self) {
        next unless $key =~ m/^on_sig_(.+)$/i;
        my $sig = uc($1);
        my $h = delete $self->{$key} or next;
        $on_sig->{$sig} = $h;
    }
    $self->{+ON_SIG} = $on_sig if $on_sig;

    return $self;
}

sub running { $_[0]->{+PID} ? 1 : 0 }

sub terminate {
    my $self = shift;

    $self->{+TERMINATED} = shift if @_;

    return $self->{+TERMINATED} //= 0;
}

sub in_correct_pid {
    my $self = shift;
    croak "Not Running" unless $self->{+PID};
    croak "Incorrect PID (did your fork leak? $$ vs $self->{+PID})" unless $$ == $self->{+PID}
}

for my $action (@ACTIONS) {
    my $key = "on_$action";

    my %inject;
    $inject{push} = sub {
        my $self = shift;
        my ($cb) = @_;
        croak "A callback is required" unless $cb;
        croak "A callback must be a coderef (got $cb)" unless ref($cb) eq 'CODE';

        my $set = $self->{$key} //= [];
        $set = [$set] unless ref($set) eq 'ARRAY';
        push @$set => $cb;
    };

    $inject{unshift} = sub {
        my $self = shift;
        my ($cb) = @_;
        croak "A callback is required" unless $cb;
        croak "A callback must be a coderef (got $cb)" unless ref($cb) eq 'CODE';

        my $set = $self->{$key} //= [];
        $set = [$set] unless ref($set) eq 'ARRAY';
        unshift @$set => $cb;
    };

    $inject{remove} = sub {
        my $self = shift;
        my ($cb) = @_;
        croak "A callback is required" unless $cb;
        croak "A callback must be a coderef (got $cb)" unless ref($cb) eq 'CODE';

        my $set = $self->{$key} //= [];
        $set = [$set] unless ref($set) eq 'ARRAY';
        @$set = grep { $_ && refaddr($cb) != refaddr($_) } @$set;
    };

    $inject{clear} = sub {
        my $self = shift;
        delete $self->{$key};
    };

    $inject{_run} = sub {
        my $self = shift;
        my (@args) = @_;

        my $set = $self->{$key} or return;
        my @out;

        my $ok = 1;
        my @err;
        for my $cb (@$set) {
            my $res = $self->try(sub { push @out => $cb->($self, @args) });
            next if $res->{ok};
            $ok = 0;
            push @err => $res->{err};
        }

        return {ok => $ok, err => join("\n" => @err), out => \@out};
    };

    for my $name (keys %inject) {
        no strict 'refs';
        *$name = set_subname "${name}_${action}" => $inject{$name};
    }
}

sub try {
    my $self = shift;
    my ($cb) = @_;

    unless ($self->{+INTERCEPT_ERRORS}) {
        $cb->();
        return {ok => 1, err => ''};
    }

    my $err;
    {
        local $@;
        return {ok => 1, err => ''} if eval { $cb->(); 1 };
        $err  = $@;
    }

    $self->debug("Peer '$self->{+NAME}' caught exception: $err");
    warn $err;

    return {ok => 0, err => $err};
}

sub run {
    my $self = shift;

    croak "Already running" if $self->{+PID};

    local $self->{+PID} = $$;

    $self->{+ORIG_SIG} = {%SIG};
    my %sig_seen;
    for my $sig (keys %{$self->{+ON_SIG}}) {
        my $key = "$sig";
        $SIG{$key} = sub { $sig_seen{$key}++ };
    }

    my $start_res = $self->_run_on_start();

    # If there was an exception on startup we do not keep going
    die "Exception in process startup, aborting" unless $start_res->{ok};

    $self->peer_delta; # Initialize it
    while (!defined $self->{+TERMINATED}) {
        my $activity;
        $self->try(sub { $activity = $self->watch(\%sig_seen) })->{ok} or next;
        next unless $activity;

        $self->_run_on_all($activity);

        if (my $sigs = delete $activity->{sigs}) {
            for my $sig (keys %$sigs) {
                my $count = delete $sigs->{$sig} or next;
                $self->_run_on_sig($sig) for $count;
            }
        }

        if (delete $activity->{pid_watch}) {
            $self->{+TERMINATED} //= 0;
            last;
        }

        if (delete $activity->{interval}) {
            $self->_run_on_interval();
            $self->{+LAST_INTERVAL} = time;
        }

        $self->_run_on_peer_delta(delete $activity->{peer_delta}) if $activity->{peer_delta};

        if (my $msgs = delete $activity->{messages}) {
            for my $msg (@$msgs) {
                $self->try(sub {
                    my $c = $msg->content;

                    $self->_run_on_message($msg);

                    if (ref($c) eq 'HASH' && $c->{request}) {
                        $self->_run_on_request_message($msg);
                        $self->try(sub { $self->handle_request($msg) });
                    }
                    else {
                        $self->_run_on_general_message($msg);
                    }
                });
            }
        }

        $self->try(sub {
            my @unhandled = keys %$activity;
            return unless @unhandled;

            die "Failed to handle activity: " . join(", " => @unhandled);
        });

        $self->{+TERMINATED} //= 0 if any { $_ } @{$self->_run_should_end()->{out}};
    }

    $self->_run_on_cleanup();

    %SIG = %{$self->{+ORIG_SIG}};

    return $self->{+TERMINATED} // 0;
}

sub watch {
    my $self = shift;
    my ($sig) = @_;

    my $client        = $self->client;
    my $interval      = $self->{+INTERVAL};
    my $have_interval = defined $interval;
    my $cycle         = $interval || 0.2;

    unless (exists $self->{+SELECT}) {
        my @message_handles = $client->have_handles_for_select      ? $client->handles_for_select      : ();
        my @peer_handles    = $client->have_handles_for_peer_change ? $client->handles_for_peer_change : ();

        if (@message_handles || @peer_handles) {
            my $s = IO::Select->new;
            $s->add(@message_handles, @peer_handles);
            $self->{+SELECT} = $s;
        }
        else {
            $self->{+SELECT} = undef;
        }
    }

    my $last_interval = $self->{+LAST_INTERVAL} //= time;

    while (1) {
        my @messages;
        my %activity;

        my $select = $self->{+SELECT};

        if ($select) {
            if ($select->can_read($cycle)) {
                @messages = $client->get_messages;
                $client->reset_handles_for_peer_change if $client->have_handles_for_peer_change;
            }
        }
        else {
            @messages = $client->get_messages;
        }

        $activity{messages} = \@messages if @messages;
        $activity{sigs}     = $sig       if $self->{+ON_SIG} && keys %$sig;

        if ($self->{+ON_PEER_DELTA}) {
            if (my $delta = $self->peer_delta) {
                $activity{peer_delta} = $delta;
            }
        }

        my $now = time;
        if ($now - $last_interval >= $interval) {
            $activity{iterval} = 1;

            # This will get reset when we run our callbacks, but put this here as a safety
            $self->{+LAST_INTERVAL} = $now;
        }

        if (my $pids = $self->{+WATCH_PIDS}) {
            $activity{pid_watch} = 1 if any { !$self->pid_is_running($_) } @$pids;
        }

        return \%activity if keys %activity;

        sleep $cycle unless $select;
    }
}

sub peer_delta {
    my $self = shift;
    my (%params) = @_;

    my $prev = $self->{+PEERS};
    my $curr = map {($_ => 1)} $self->client->peers;

    my $delta = { %$curr };
    if ($prev) {
        # Any that exist, and already existed will be set to 0
        # Any that used to exist, but do not now will be set to -1
        # Any that did not exist, but do now will be set to 1
        for my $peer (keys %$prev) {
            $delta->{$_}--;
            delete $delta->{$_} unless $delta->{$_};
        }
    }

    $self->{+PEERS} = $curr unless $params{peek};

    return $delta if keys %$delta;
    return undef;
}

sub peer {
    my $self = shift;
    my ($name, @params) = @_;

    return $self->get_peer($name) unless @params;

    return $self->new_peer($name, @params)
        unless $self->client->peer_exists($name);

    return $self->renew_peer($name, @params);
}

sub new_peer {
    my $self = shift;
    my ($name, @params) = @_;

    croak "Peer '$name' already exists" if $self->{+PEER_CACHE}->{$name} || $self->client->peer_exists($name);

    return $self->_new_peer(@_);
}

sub renew_peer {
    my $self = shift;
    my ($name, @params) = @_;

    my $client = $self->client;

    croak "Peer '$name' does not exist to renew" unless $client->peer_exists($name);
    croak "Peer '$name' is already active" if $client->peer_active($name);

    return $self->_new_peer(@_);
}

sub _new_peer {
    my $self = shift;
    my $name = shift;

    my %params = (@_ == 1 ? %{$_[0]} : @_);

    my $class = require_mod(delete $params{class} // 'IPC::Manager::Coordinator::This');
    my $this = $class->new(
        %params,

        NAME()    => $name,
        VIA()     => $self->{+VIA},
        REAL_IO() => $self->{+REAL_IO},
    );

    my $pid = fork // die "Could not fork new process for peer '$name': $!";

    return $self->get_peer($name) if $pid;

    my $exit;
    eval {
        if (my $sig = $self->{+ORIG_SIG}) {
            %SIG = %$sig;
        }

        $exit = $this->run();
        1;
    } and exit($exit);
    warn $@;
    exit(255);
}

1;

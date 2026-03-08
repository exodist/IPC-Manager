package IPC::Manager::Service;
use strict;
use warnings;

# Not included in role:
use Carp qw/croak/;
use POSIX qw/:sys_wait_h/;
use List::Util qw/any/;
use Time::HiRes qw/time sleep/;
use Test2::Util::UUID qw/gen_uuid/;

use IPC::Manager::ServiceHandle();
use IPC::Manager::ServicePeer();

use Role::Tiny;

with 'IPC::Manager::ServiceSelect';
with 'IPC::Manager::ServiceRequests';

# Included in role:
use IPC::Manager::Util qw/pid_is_running/;

requires qw{
    new
    orig_io
    name
    run
    ipcm_info
    pid
    watch_pids
    handle_request
};

sub cycle            { 0.2 }
sub interval         { 0.2 }
sub use_posix_exit   { 0 }
sub intercept_errors { 0 }

sub terminated    { $_[0]->{_TERMINATED} }
sub is_terminated { defined $_[0]->{_TERMINATED} ? 1 : 0 }
sub terminate     { $_[0]->{_TERMINATED} = pop if @_ > 1; $_[0]->{_TERMINATED} //= 0 }

sub peer_class   { 'IPC::Manager::ServicePeer' }
sub handle_class { 'IPC::Manager::ServiceHandle' }

sub signals_to_grab { () }

sub redirect      { }
sub pre_fork_hook { }

sub run_on_all             { }
sub run_on_cleanup         { }
sub run_on_general_message { }
sub run_on_interval        { }
sub run_on_peer_delta      { }
sub run_on_sig             { }
sub run_on_start           { }
sub run_should_end         { }

#<<<    Do not tidy this
sub _run_on_all        { my ($self, @args) = @_; $self->try(sub { $self->run_on_all(@args)        }) }
sub _run_on_cleanup    { my ($self, @args) = @_; $self->try(sub { $self->run_on_cleanup(@args)    }) }
sub _run_on_interval   { my ($self, @args) = @_; $self->try(sub { $self->run_on_interval(@args)   }) }
sub _run_on_message    { my ($self, @args) = @_; $self->try(sub { $self->run_on_message(@args)    }) }
sub _run_on_peer_delta { my ($self, @args) = @_; $self->try(sub { $self->run_on_peer_delta(@args) }) }
sub _run_on_sig        { my ($self, @args) = @_; $self->try(sub { $self->run_on_sig(@args)        }) }
sub _run_on_start      { my ($self, @args) = @_; $self->try(sub { $self->run_on_start(@args)      }) }
sub _run_should_end    { my ($self, @args) = @_; $self->try(sub { $self->run_should_end(@args)    }) }
#>>>

sub clear_service_fields {
    my $self = shift;

    $self->clear_serviceselect_fields;
    $self->clear_servicerequests_fields();

    delete $self->{_CLIENT};
    delete $self->{_LAST_INTERVAL};
    delete $self->{_ORIG_SIG};
    delete $self->{_PEER_CACHE};
    delete $self->{_PEER_STATE};
    delete $self->{_SIGS_SEEN};
    delete $self->{_TERMINATED};
    delete $self->{_WORKERS};
}

sub register_worker {
    my $self = shift;
    my ($name, $pid) = @_;

    $self->{_WORKERS}->{$pid} = $name;
}

sub workers {
    my $self = shift;
    return $self->{_WORKERS};
}

sub reap_workers {
    my $self = shift;

    my $workers = $self->{_WORKERS} or return;

    my %out;
    for my $pid (keys %$workers) {
        local $?;
        my $check = waitpid($pid, WNOHANG) or next;
        my $exit = $?;

        my $name = delete $workers->{$pid};

        if ($check == $pid) {
            $out{$pid} = {name => $name, exit => $exit};
        }
        elsif ($check < 0) {
            $out{$pid} = {name => $name, exit => $check};
        }
        else {
            die "Nonsensical return from waitpid";
        }
    }

    return \%out;
}

sub run_on_message {
    my $self = shift;
    my ($msg) = @_;

    my $c = $msg->content;

    if (ref($c) eq 'HASH') {
        return $self->run_on_request_message($msg)  if $c->{ipcm_request_id};
        return $self->run_on_response_message($msg) if $c->{ipcm_response_id};
    }

    return $self->run_on_general_message($msg);
}

sub run_on_response_message {
    my $self = shift;
    my ($msg) = @_;

    my $resp = $msg->content;
    $self->handle_response($resp, $msg);

    return;
}

sub run_on_request_message {
    my $self = shift;
    my ($msg) = @_;

    my $peer = $msg->from;

    my $req  = $msg->content;
    my $resp = $self->handle_request($req, $msg);

    $self->client->send_message(
        $peer,
        {
            icpm_response_id => $req->{icpm_request_id},
            response         => $resp,
        }
    );

    return;
}

sub client {
    return $_[0]->{_CLIENT} if $_[0]->{_CLIENT};
    require IPC::Manager;
    return $_[0]->{_CLIENT} = IPC::Manager->ipcm_connect($_[0]->name, $_[0]->ipcm_info);
}

sub in_correct_pid {
    my $self = shift;
    my $pid  = $self->pid;
    croak "Incorrect PID (did your fork leak? $$ vs $pid)" unless $$ == $pid;
}

sub kill {
    my $self = shift;
    my ($sig) = @_;
    croak "A signal is required" unless defined $sig;
    CORE::kill($sig, $self->pid);
}

sub debug {
    my $self = shift;

    my $io = $self->orig_io;
    my $fh = $io ? $io->{stderr} // $io->{stdout} // \*STDERR : \*STDERR;

    print $fh @_;
}

sub handle {
    my $self = shift;
    my (%params) = @_;

    croak "'name' is a required parameter" unless $params{name};

    return $self->handle_class->new(
        %params,
        ipcm_info => $self->ipcm_info,
    );
}

sub peer {
    my $self = shift;
    my ($name, %params) = @_;

    croak "peer() can only be called on the service in the service process"
        unless $self->pid == $$;

    return $self->{_PEER_CACHE}->{$name} //= $self->peer_class->new(
        %params,

        name      => $name,
        service   => $self,
        ipcm_info => $self->ipcm_info,
    );
}

sub try {
    my $self = shift;
    my ($cb) = @_;

    unless ($self->intercept_errors) {
        my $out = $cb->();
        return {ok => 1, err => '', $out => $out};
    }

    my $err;
    {
        local $@;
        my $out;
        if (eval { $out = $cb->(); 1 }) {
            return {ok => 1, err => '', out => $out};
        }
        $err  = $@;
    }

    $self->debug("Peer '" . $self->name . "' caught exception: $err");
    warn $err;

    return {ok => 0, err => $err};
}

sub peer_delta {
    my $self = shift;
    my (%params) = @_;

    my $prev = $self->{_PEER_STATE};
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

    $self->{_PEER_STATE} = $curr unless $params{peek};

    return $delta if keys %$delta;
    return undef;
}

sub select_handles {
    my $self = shift;
    my $client = $self->client;

    my @message_handles = $client->have_handles_for_select      ? $client->handles_for_select      : ();
    my @peer_handles    = $client->have_handles_for_peer_change ? $client->handles_for_peer_change : ();

    return (@message_handles, @peer_handles);
}

sub watch {
    my $self = shift;

    my $sig           = $self->{_SIGS_SEEN} // {};
    my $cycle         = $self->cycle;
    my $client        = $self->client;
    my $interval      = $self->interval;
    my $have_interval = defined $interval;

    my $last_interval = $self->{_LAST_INTERVAL} //= time;

    my $term = $self->terminated;

    while (1) {
        my @messages;
        my %activity;

        my $select = $self->select;

        if ($select) {
            if ($select->can_read($cycle)) {
                @messages = $client->get_messages;
                $client->reset_handles_for_peer_change if $client->have_handles_for_peer_change;
            }
        }
        else {
            @messages = $client->get_messages;
        }

        my $term2 = $self->terminated;
        if (defined($term2) && !(defined($term) && $term == $term2)) {
            $activity{terminated} = {value => $term2};
        }

        $activity{messages} = \@messages if @messages;
        $activity{sigs}     = $sig       if keys %$sig;

        if (my $delta = $self->peer_delta) {
            $activity{peer_delta} = $delta;
        }

        my $now = time;
        if ($now - $last_interval >= $interval) {
            $activity{iterval} = 1;

            # This will get reset when we run our callbacks, but put this here as a safety
            $self->{_LAST_INTERVAL} = $now;
        }

        if (my $pids = $self->watch_pids) {
            $activity{pid_watch} = 1 if any { !$self->pid_is_running($_) } @$pids;
        }

        return \%activity if keys %activity;

        sleep $cycle unless $select;
    }
}

sub run {
    my $self = shift;

    $self->in_correct_pid;

    my %sig_seen;
    $self->{_ORIG_SIG}  = {%SIG};
    $self->{_SIGS_SEEN} = \%sig_seen;

    for my $sig ($self->signals_to_grab) {
        my $key = "$sig";
        $SIG{$key} = sub { $sig_seen{$key}++ };
    }

    my $start_res = $self->_run_on_start();

    # If there was an exception on startup we do not keep going
    die "Exception in process startup, aborting" unless $start_res->{ok};

    $self->peer_delta; # Initialize it
    until ($self->is_terminated) {
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
            $self->terminate(0);
            last;
        }

        if (delete $activity->{interval}) {
            $self->_run_on_interval();
            $self->{_LAST_INTERVAL} = time;
        }

        $self->_run_on_peer_delta(delete $activity->{peer_delta}) if $activity->{peer_delta};

        if (my $msgs = delete $activity->{messages}) {
            for my $msg (@$msgs) {
                $self->try(sub { $self->_run_on_message($msg) });
            }
        }

        $self->try(sub {
            my @unhandled = keys %$activity;
            return unless @unhandled;

            die "Failed to handle activity: " . join(", " => @unhandled);
        });

        $self->terminate(0) if $self->_run_should_end()->{out};
    }

    $self->_run_on_cleanup();

    %SIG = %{$self->{_ORIG_SIG}};

    return $self->terminated // 0;
}

1;

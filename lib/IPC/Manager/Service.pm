package IPC::Manager::Service;
use strict;
use warnings;

use Carp qw/croak confess/;
use List::Util qw/max/;

my @ACTIONS;
BEGIN {
    @ACTIONS = qw{
        on_all
        on_cleanup
        on_general_message
        on_interval
        on_peer_delta
        on_start
        on_unhandled
        should_end
    };
}

use Object::HashBase(
    qw{
        <name
        <orig_io
        <ipcm_info
        <redirect

        pid
        use_posix_exit
        intercept_errors
        watch_pids

        <interval
        <cycle
        +on_sig
        +handle_request
        +handle_response
    },

    map { "<$_" } @ACTIONS,
);

use Role::Tiny::With;
with 'IPC::Manager::Role::Service';

sub signals_to_grab { keys %{$_[0]->{+ON_SIG}} }
sub handle_request  { $_[0]->{+HANDLE_REQUEST}->(@_) }
sub handle_response { $_[0]->{+HANDLE_RESPONSE}->(@_) }

sub init {
    my $self = shift;

    $self->clear_service_fields();

    $self->{+CYCLE}            //= $self->IPC::Manager::Role::Service::cycle();
    $self->{+INTERVAL}         //= $self->IPC::Manager::Role::Service::interval();
    $self->{+USE_POSIX_EXIT}   //= $self->IPC::Manager::Role::Service::use_posix_exit();
    $self->{+INTERCEPT_ERRORS} //= $self->IPC::Manager::Role::Service::intercept_errors();

    if ($self->{+ON_ALL}) {
        $self->{+HANDLE_REQUEST}  //= sub { return () };
        $self->{+HANDLE_RESPONSE} //= sub { return () };
    }
    else {
        my $req_handler  = $self->{+HANDLE_REQUEST} or croak "Either 'on_all' or 'handle_request' callback is required";
        my $resp_handler = $self->{+HANDLE_RESPONSE} //= sub { confess "Got a response, but no response handler set" };

        croak "'handle_request' must be a coderef"  unless ref($req_handler) eq 'CODE';
        croak "'handle_response' must be a coderef" unless ref($resp_handler) eq 'CODE';
    }

    for my $action (@ACTIONS) {
        my $in = delete $self->{$action};
        my $do = $in ? (ref($in) eq 'ARRAY' ? $in : [$in]) : [];

        my @bad = grep { ref($_) ne 'CODE' } @$do;
        croak "All '$action' callbacks must be coderefs, got: " . join(', ' => @bad) if @bad;

        $self->{$action} = $do;
    }

    if (my $sigs = delete $self->{+ON_SIG}) {
        croak "'on_sig' must be a hashref" unless ref($sigs) eq 'HASH';

        my $new = {};
        for my $sig (keys %$sigs) {
            my $do = $sigs->{$sig} or next;
            $do = [$do] unless ref($do) eq 'ARRAY';
            my @bad = grep { ref($_) ne 'CODE' } @$do;
            croak "All signal handlers must be coderefs, got: " . join(', ' => @bad) if @bad;
            $new->{$sig} = $do;
        }

        $self->{+ON_SIG} = $new;
    }
    else {
        $self->{+ON_SIG} = {};
    }
}

#<<<    Do not tidy this
sub clear_on_sig   { delete $_[0]->{+ON_SIG}->{$_[1]} }
sub push_on_sig    { push @{$_[0]->{+ON_SIG}->{$_[1]}}    => $_[2] }
sub unshift_on_sig { unshift @{$_[0]->{+ON_SIG}->{$_[1]}} => $_[2] }
sub run_on_sig     { my @args = @_; [map { $_->(@args) } @{$_[0]->{+ON_SIG}->{$_[1]}}] }
sub remove_on_sig  { my $cb = $_[2]; @{$_[0]->{+ON_SIG}->{$_[1]}} = grep { $_ != $cb } @{$_[0]->{+ON_SIG}->{$_[1]}} }
#>>>

BEGIN {
    my %inject;

    # Should end needs to return true/false
    $inject{'run_should_end'} = sub { my @args = @_; my $count = grep { $_->(@args) } @{$_[0]->{should_end}}; $count ? 1 : 0 };

    for my $action (@ACTIONS) {
        my $key = $action;

        #<<<    Do not tidy this
        $inject{"clear_$key"}   //= sub { delete $_[0]->{$key} };
        $inject{"push_$key"}    //= sub { push @{$_[0]->{$key}}    => $_[1] };
        $inject{"unshift_$key"} //= sub { unshift @{$_[0]->{$key}} => $_[1] };
        $inject{"run_$key"}     //= sub { my @args = @_; [map { $_->(@args) } @{$_[0]->{$key}}] };
        $inject{"remove_$key"}  //= sub { my $cb = $_[1]; @{$_[0]->{$key}} = grep { $_ != $cb } @{$_[0]->{$key}} };
        #>>>
    }

    no strict 'refs';
    *{$_} = $inject{$_} for keys %inject;
}

1;

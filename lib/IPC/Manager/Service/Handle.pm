package IPC::Manager::Service::Handle;
use strict;
use warnings;

use Carp qw/croak/;
use Time::HiRes qw/sleep time/;
use Test2::Util::UUID qw/gen_uuid/;

use Role::Tiny::With;

with 'IPC::Manager::Role::Service::Select';
with 'IPC::Manager::Role::Service::Requests';

use Object::HashBase qw{
    <service_name
    <name
    <ipcm_info

    interval

    +client

    +request_callbacks
    +requests

    +buffer
};

sub init {
    my $self = shift;

    $self->clear_servicerequests_fields;
    $self->clear_serviceselect_fields;

    croak "'service_name' is a required attribute" unless $self->{+SERVICE_NAME};
    croak "'ipcm_info' is a required attribute" unless $self->{+IPCM_INFO};

    $self->{+INTERVAL} //= 0.2;

    $self->{+NAME} //= gen_uuid();
}

sub select_handles {
    my $self   = shift;
    my $client = $self->client;
    return $client->have_handles_for_select ? $client->handles_for_select : ();
}

sub client {
    my $self = shift;
    return $self->{+CLIENT} if $self->{+CLIENT};

    require IPC::Manager;
    return $self->{+CLIENT} = IPC::Manager->ipcm_connect($self->{+NAME}, $self->{+IPCM_INFO});
}

sub sync_request {
    my $self = shift;
    my $id = $self->send_request(@_);
    return $self->await_response($id);
}

sub await_response {
    my $self = shift;
    my ($id) = @_;

    while (1) {
        my @out = $self->get_response($id);
        return $out[0] if @out;

        $self->poll();
    }
}

sub await_all_responses {
    my $self = shift;

    $self->poll while $self->have_pending_responses;

    return;
}

sub messages {
    my $self = shift;
    my $messages = delete $self->{+BUFFER};
    return unless $messages;
    return @$messages;
}

sub poll {
    my $self = shift;
    my ($timeout) = @_;

    my $client = $self->client;

    my @messages;
    if (my $select = $self->select) {
        if ($select->can_read($timeout)) {
            @messages = $client->get_messages;
        }
    }
    else {
        my $start = $timeout ? time : 0;

        while (1) {
            @messages = $client->get_messages;
            last if @messages;

            if (defined $timeout) {
                last unless $timeout; # timeout is 0

                my $delta = time - $start;
                last if $delta >= $timeout
            }

            sleep $self->{+INTERVAL};
        }
    }

    return unless @messages;

    # handle the messages
    # Split into regular message to go in the buffer and handle responses
    for my $msg (@messages) {
        my $c = $msg->content;

        if (ref($c) eq 'HASH' && $c->{ipcm_response_id}) {
            $self->handle_response($c, $msg);
        }
        else {
            push @{$self->{+BUFFER}} => $msg;
        }
    }

    return scalar @messages;
}

1;

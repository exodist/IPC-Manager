package IPC::Manager::Role::Service::Requests;
use strict;
use warnings;

# Not included in role:
use Carp qw/croak/;
use List::Util qw/any/;
use Test2::Util::UUID qw/gen_uuid/;

use Role::Tiny;

requires qw{
    client
};

sub clear_servicerequests_fields {
    my $self = shift;
    delete $self->{_RESPONSES};
    delete $self->{_RESPONSE_HANDLER};
}

sub have_pending_responses {
    my $self = shift;

    return 1 if $self->{_RESPONSES}        && any { !defined($_) } values %{$self->{_RESPONSES}};
    return 1 if $self->{_RESPONSE_HANDLER} && any { defined($_) } values %{$self->{_RESPONSE_HANDLER}};
    return 0;
}

sub handle_response {
    my $self = shift;
    my ($resp, $msg) = @_;

    my $id = $resp->{ipcm_response_id};

    if (my $handler = delete $self->{_RESPONSE_HANDLER}->{$id}) {
        $handler->($resp, $msg);
    }
    else {
        croak "Got an unexpected response for '$id'" unless exists $self->{_RESPONSES}->{$id};
        croak "Got an extra response for '$id'" if defined $self->{_RESPONSES}->{$id};
        $self->{_RESPONSES}->{$id} = $resp;
    }

    return;
}

sub send_request {
    my $self = shift;
    my ($peer, $req, $cb) = @_;

    my $id = gen_uuid();

    $self->client->send_message(
        $peer,
        {
            ipcm_request_id => $id,
            request         => $req,
        }
    );

    if ($cb) {
        $self->{_RESPONSE_HANDLER}->{$id} = $cb;
    }
    else {
        $self->{_RESPONSES}->{$id} = undef;
    }

    return $id;
}

sub get_response {
    my $self = shift;
    my ($resp_id) = @_;

    my $resps = $self->{_RESPONSES} // {};

    croak "Response id '$resp_id' has a callback assigned, cannot use both get_response() and a callback"
        if exists $self->{_RESPONSE_HANDLER}->{$resp_id};

    croak "Not expecting a response with id '$resp_id'"
        unless exists $resps->{$resp_id};

    return undef unless defined $resps->{$resp_id};
    return delete $resps->{$resp_id};
}

1;

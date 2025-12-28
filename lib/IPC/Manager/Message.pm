package IPC::Manager::Message;
use strict;
use warnings;

use Carp qw/croak/;
use Time::HiRes qw/time/;
use Scalar::Util qw/blessed/;
use Test2::Util::UUID qw/gen_uuid/;

use Object::HashBase qw{
    <from
    <to
    <broadcast
    <stamp
    <id
    <content
};

sub init {
    my $self = shift;

    croak "'from' is a required attribute"    unless $self->{+FROM};
    croak "'content' is a required attribute" unless defined $self->{+CONTENT};

    croak "Message must either have a 'to' or 'broadcast' attribute" unless $self->{+TO} || $self->{+BROADCAST};

    $self->{+ID}    //= gen_uuid();
    $self->{+STAMP} //= time;
}

sub is_terminate {
    my $self = shift;

    my $content = $self->{+CONTENT} or return 0;
    return 0 unless ref($content) eq 'HASH';
    return 1 if $content->{terminate};
    return 0;
}

sub TO_JSON { +{ %{$_[0]} } }

sub clone {
    my $self = shift;
    my %params = @_;
    my $copy = { %$self };
    delete $copy->{+ID};
    $copy = { %$copy, %params };
    return blessed($self)->new($copy);
}

1;

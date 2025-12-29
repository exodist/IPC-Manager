package IPC::Manager::Spawn;
use strict;
use warnings;

use Carp qw/croak/;

use overload(
    fallback => 1,

    '""' => sub { $_[0]->connect_string },
);

use Object::HashBase qw{
    <protocol
    <info
    <guard
    <stash
};

sub init {
    my $self = shift;

    $self->{+GUARD} //= 1;

    croak "'protocol' is a required attribute" unless $self->{+PROTOCOL};
    croak "'info' is a required attribute"     unless $self->{+INFO};
}

sub connect_string {
    my $self = shift;
    return join '|' => @{$self}{PROTOCOL(), INFO()};
}

sub DESTROY {
    my $self = shift;
    return unless $self->{+GUARD};
    $self->{+PROTOCOL}->unspawn($self->{+INFO}, delete $self->{+STASH});
}

1;

package IPC::Manager::ServiceSelect;
use strict;
use warnings;

# Not included in role:
use Carp qw/croak/;

use Role::Tiny;

requires qw{
    select_handles
};

sub clear_serviceselect_fields {
    my $self = shift;
    delete $self->{_SELECT};
}

sub select {
    my $self = shift;

    return $self->{_SELECT} if exists $self->{_SELECT};

    my @handles = $self->select_handles;
    return $self->{_SELECT} = undef unless @handles;

    require IO::Select;
    my $s = IO::Select->new;
    $s->add(@handles);
    return $self->{_SELECT} = $s;
}

1;

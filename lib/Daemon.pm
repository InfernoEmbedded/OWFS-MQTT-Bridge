package Daemon;

use strict;
use warnings;
use English;


##
# Write a debug message
sub debug {
	my ($self, @args) = @ARG;

	return unless $self->{DEBUG};

	warn @args, "\n";
}


1;
package Daemon;

use strict;
use warnings;
use English;

use AnyEvent;

use DateTime;
use DateTime::Format::Strptime;
use Time::HiRes qw(time);

##
# Constructor
# @param generalConfig the general configuration
sub new {
	my ($class, $generalConfig) = @ARG;

	my $self = {};
	bless $self, $class;

	$self->{GENERAL_CONFIG} = $generalConfig;
	$self->{TIMEZONE} = $generalConfig->{timezone};

	# List of pending tasks
	$self->{CVS} = [];
	$self->setupCVCleanup();

	return $self;
}

##
# Write a debug message
sub debug {
	my ($self, @args) = @ARG;

	return unless $self->{DEBUG};

	warn $self->getCurrentTimeLog(), ': ', @args, "\n";
}


##
# Clean up any outstanding CVs
sub setupCVCleanup {
	my ($self) = @ARG;

	$self->{CLEANUP_CVS_TIMER} = AnyEvent->timer(
		after    => 0,
		interval => 10,
		cb       => sub {
			my @pendingCvs;

			foreach my $cv ( @{ $self->{CVS} } ) {
				push( @pendingCvs, $cv ) if !$cv->ready();
			}

			$self->{CVS} = \@pendingCvs;
		}
	);
}


##
# Get the current time in a db suitable format
sub getCurrentTimeDB {
	my ($self) = @ARG;

	my $formatter = DateTime::Format::Strptime->new( pattern => '%Y-%m-%d %T.%3N', );

	my $time = DateTime->from_epoch(
		time_zone => $self->{TIMEZONE},
		epoch     => time(),
		formatter => $formatter,
	);

	return $time;
}

##
# Get the current time in a log suitable format
sub getCurrentTimeLog {
	my ($self) = @ARG;

	return $self->getCurrentTimeDB();
}

1;
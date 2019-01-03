package Daemon;

use strict;
use warnings;
use English;

use Sys::Syslog qw(:standard :macros);

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

	openlog( 'ndelay,pid', LOG_DAEMON );

	return $self;
}

##
# Write a debug message
sub debug {
	my ($self, @args) = @ARG;

	return unless $self->{DEBUG};

	my ($package, $filename, $line, $sub) = caller(1);

	warn $self->getCurrentTimeLog(), ": $filename:$line:$sub(): ", @args, "\n";
}

##
# Write a debug message
sub log {
	my ($self, @args) = @ARG;

	syslog( LOG_DAEMON, join(' ', @args) );
}

##
# Write a debug message
sub logError {
	my ($self, @args) = @ARG;

	$self->debug(@args);
	syslog( LOG_ERR, join(' ', @args) );
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

##
# Called when a KILL is received
# Does nothing here, but can be overidden to extend the behavior
sub kill {
}


1;
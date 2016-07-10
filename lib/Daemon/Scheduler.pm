package Daemon::Scheduler;

use strict;
use warnings;
use English;

use AnyEvent;
use AnyEvent::MQTT;
use AnyEvent::Loop;

use Schedule::Cron;
use JSON::Parse;

use base 'Daemon';

##
# Create a new scene daemon
# @param class the class of this object
# @param generalConfig the general configuration
# @param mqtt the MQTT instance
sub new {
	my ( $class, $generalConfig, $mqtt ) = @ARG;

	my $self = $class->SUPER::new($generalConfig);
	bless $self, $class;

	$self->{DEBUG} = 1;

	$self->{MQTT} = $mqtt;
	$self->{CRON} = new Schedule::Cron(
		sub {
			$self->logError( "Unhandled cron request: " . join( ', ', @ARG ) );
		},
	);
	$self->{CRON_PID} = undef;

	$self->{SCHEDULER_ON}  = {};
	$self->{SCHEDULER_OFF} = {};

	$self->setupScheduleSubscriptions();

	return $self;
}

##
# Set up the listeners for scene subscribed topics
sub setupScheduleSubscriptions {
	our ($self) = @ARG;

	$self->{MQTT}->subscribe(
		topic    => 'schedule/+/on',    # JSON array of crontab entries
		callback => sub {
			my ( $topic, $message ) = @ARG;
			$self->setScheduleOn( $topic, $message );
		}
	);
	$self->debug("Subscribed to 'schedule/+/on'");

	$self->{MQTT}->subscribe(
		topic    => 'schedule/+/off',    # JSON array of crontab entries
		callback => sub {
			my ( $topic, $message ) = @ARG;
			$self->setScheduleOff( $topic, $message );
		}
	);
	$self->debug("Subscribed to 'schedule/+/off'");
}

##
# Restart the cron daemon
sub restartCron {
	my ($self) = @ARG;

	if ( defined $self->{CRON_PID} ) {
		kill 'KILL', $self->{CRON_PID};
		$self->debug("waiting for Cron daemon '$self->{CRON_PID}' to die");
		waitpid( $self->{CRON_PID}, 0 );
		$self->debug("Cron daemon '$self->{CRON_PID}' is dead");
	}

	$self->{CRON_PID} = $self->{CRON}->run( catch => 1, detach => 1 );
	$self->debug("Cron daemon has pid '$self->{CRON_PID}'");
}

##
# Set the schedule for an On action
# @param topic	the MQTT topic
# @param message the MQTT message, a JSON array of crontab entries
sub setScheduleOn {
	my ( $self, $topic, $message ) = @ARG;

	$topic =~ /schedule\/(.+)\/on/
	  or return;

	my $device = $1;

	my $crons = JSON::Parse::parse_json($message);

	if ( defined $self->{SCHEDULER_ON}->{$device} ) {
		foreach my $entry ( @{ $self->{SCHEDULER_ON}->{$device} } ) {
			$self->{CRON}->delete_entry($entry);
		}

		delete $self->{SCHEDULER_ON}->{$device};
	}

	$self->{SCHEDULER_ON}->{$device} = [];

	foreach my $cron ( @{$crons} ) {
		$self->debug(
			"Adding cron entry to activate schedule '$device': '$cron'");

		push @{ $self->{SCHEDULER_ON}->{$device} },
		  $self->{CRON}
		  ->add_entry( $cron, sub { $self->activateSchedule($device) } );
	}

	$self->restartCron();
}

##
# Set the schedule for an Off action
# @param topic	the MQTT topic
# @param message the MQTT message, a JSON array of crontab entries
sub setScheduleOff {
	my ( $self, $topic, $message ) = @ARG;

	$topic =~ /schedule\/(.+)\/off/
	  or return;

	my $device = $1;

	my $crons = JSON::Parse::parse_json($message);

	if ( defined $self->{SCHEDULER_OFF}->{$device} ) {
		foreach my $entry ( @{ $self->{SCHEDULER_OFF}->{$device} } ) {
			$self->{CRON}->delete_entry($entry);
		}

		delete $self->{SCHEDULER_OFF}->{$device};
	}

	$self->{SCHEDULER_OFF}->{$device} = [];

	foreach my $cron ( @{$crons} ) {
		$self->debug(
			"Adding cron entry to activate schedule '$device': '$cron'");

		push @{ $self->{SCHEDULER_OFF}->{$device} },
		  $self->{CRON}
		  ->add_entry( $cron, sub { $self->deactivateSchedule($device) } );
	}

	$self->restartCron();
}

##
# Activate a schedule
sub activateSchedule {
	my ( $self, $device ) = @ARG;

	push @{ $self->{CVS} },
	  $self->{MQTT}->publish(
		topic   => "schedule/$device/active",
		message => 1,
		retain => 1,
	  );
}

##
# Deactivate a schedule
sub deactivateSchedule {
	my ( $self, $device ) = @ARG;

	push @{ $self->{CVS} },
	  $self->{MQTT}->publish(
		topic   => "schedule/$device/active",
		message => 0,
		retain => 1,
	  );
}

##
# Kill the detached cron process
sub kill {
	my ($self) = @ARG;

	$self->debug("Killing child cron '$self->{CRON_PID}'");
	kill 'KILL', $self->{CRON_PID};
	$self->debug("waiting for Cron daemon '$self->{CRON_PID}' to die");
	waitpid( $self->{CRON_PID}, 0 );
	$self->debug("Cron daemon '$self->{CRON_PID}' is dead");
}

1;

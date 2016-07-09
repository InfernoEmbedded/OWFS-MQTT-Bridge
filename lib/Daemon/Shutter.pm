package Daemon::Shutter;

use strict;
use warnings;
use English;

use AnyEvent;
use AnyEvent::MQTT;
use AnyEvent::Loop;

use JSON::Parse;

use base 'Daemon';

##
# Create a new shutter daemon
# @param class the class of this object
# @param generalConfig the general configuration
# @param mqtt the MQTT instance
sub new {
	my ( $class, $generalConfig, $mqtt) = @ARG;

	my $self = $class->SUPER::new($generalConfig);
	bless $self, $class;

	$self->{DEBUG} = 1;

	$self->{MQTT} = $mqtt;
	$self->{DURATION} = {};
	$self->{STATE} = {};
	$self->{TIMERS} = {};

	$self->setupShutterSubscriptions();

	return $self;
}


##
# Set up the listeners for shutter subscribed topics
sub setupShutterSubscriptions {
	our ($self) = @ARG;
	$self->{MQTT}->subscribe(
		topic    => 'shutter/+/state', # 0 = closed, 1 = open, 0.5 = half open
		callback => sub {
			my ( $topic, $message ) = @ARG;
			$self->setShutterState($topic, $message);
		}
	);
	$self->debug("Subscribed to 'shutter/+/state'");

	$self->{MQTT}->subscribe(
		topic    => 'shutter/+/duration', # seconds from fully closed to fully open
		callback => sub {
			my ( $topic, $message ) = @ARG;
			$self->setShutterDuration($topic, $message);
		}
	);
	$self->debug("Subscribed to 'shutter/+/duration'");

	$self->{MQTT}->subscribe(
		topic    => 'shutter/+/reset', # Reinit the shutter
		callback => sub {
			my ( $topic, $message ) = @ARG;
			$topic =~ /shutter\/(.+)\/reset/ or
				return;

			my $device = $1;
			$self->initShutter($device);
		}
	);
	$self->debug("Subscribed to 'shutter/+/reset'");
}

##
# Save the shutter duration
# @param topic	the MQTT topic
# @param message the MQTT message (duration in seconds to go from full open  to closed)
sub setShutterDuration {
	my ($self, $topic, $message) = @ARG;

	$topic =~ /shutter\/(.+)\/duration/ or
		return;

	my $device = $1;

	my $mustInit = !defined $self->{DURATION}->{$device};
	$self->debug("Setting shutter duration for '$device' to '$message', mustInit='$mustInit'");
	$self->debug("state is " . (defined $self->{STATE}->{$device} ? 'defined' : 'undefined'));

	$self->{DURATION}->{$device} = $message;
	if ($mustInit && defined $self->{STATE}->{$device}) {
		$self->initShutter($device);
	}

	$self->debug("Duration done, self is '$self'");
}

##
# Change the state of a shutter
# @param topic	the MQTT topic
# @param message the MQTT message Floating point value between 0 = closed & 1 = open
sub setShutterState {
	my ($self, $topic, $message) = @ARG;

	$topic =~ /shutter\/(.+)\/state/ or
		return;

	my $device = $1;

	my $mustInit = !defined $self->{STATE}->{$device};
	$self->debug("Setting shutter state for '$device' to '$message', mustInit='$mustInit'");
	$self->debug("duration is " . (defined $self->{DURATION}->{$device} ? 'defined' : 'undefined'));

	if ($mustInit) {
		$self->{STATE}->{$device} = $message;
		if (defined $self->{DURATION}->{$device}) {
			$self->initShutter($device);
		}
	} elsif (defined $self->{STATE}->{$device} && defined $self->{DURATION}->{$device}) {
		$self->setShutter($device, $message);
	}

	$self->debug("State done, self is '$self'");
}

##
# Initialise a shutter so that the physical state matches the logical one
# drives the shutter fully closed, then open it to the requested state
# Note that this assumes the shutter has inbuilt limit switches to prevent damage
# @param device the device to init
sub initShutter {
	my ($self, $device) = @ARG;

	$self->debug("Initialising shutter '$device'");

	my $cv = $self->{MQTT}->publish(
		topic   => "shutter/$device/close",
		message => 1,
	);

	$self->{TIMERS}->{$device} = AnyEvent->timer(
		after    => $self->{DURATION}->{$device},
		cv		=> $cv,
		cb       => sub {
			$self->{MQTT}->publish(
				topic   => "shutter/$device/close",
				message => 0,
				cv => $cv,
			);
			$self->setShutter($device, $self->{STATE}->{$device});
		},
	);

	push @{ $self->{CVS} }, $cv;
}

##
# Open/close a shutter
# @param device the shutter device
# @param state the requested state
sub setShutter {
	my ($self, $device, $state) = @ARG;

	return unless defined ($self->{STATE});
	my $currentState = $self->{STATE}->{$device};

	my $delta = $state - $currentState;
	$self->debug("Delta for device '$device' = '$delta'");
	return if $delta == 0;

	if ($delta > 0) {
		my $cv = $self->{MQTT}->publish(
			topic   => "shutter/$device/open",
			message => 1,
		);

		$self->{TIMERS}->{$device} = AnyEvent->timer(
			after    => $self->{DURATION}->{$device} * $delta,
			cv		=> $cv,
			cb       => sub {
				$self->{MQTT}->publish(
					topic   => "shutter/$device/open",
					message => 0,
					cv => $cv,
				);
			},
		);
		$self->{STATE}->{$device} = $state;
	} else { # $delta <= 0
		my $cv = $self->{MQTT}->publish(
			topic   => "shutter/$device/close",
			message => 1,
		);

		$self->{TIMERS}->{$device} = AnyEvent->timer(
			after    => $self->{DURATION}->{$device} * $delta * -1,
			cv		=> $cv,
			cb       => sub {
				$self->{MQTT}->publish(
					topic   => "shutter/$device/close",
					message => 0,
					cv => $cv,
				);
			},
		);
		$self->{STATE}->{$device} = $state;
	}
}


1;

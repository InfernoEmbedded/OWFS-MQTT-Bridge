package Daemon::Scene;

use strict;
use warnings;
use English;

use AnyEvent;
use AnyEvent::MQTT;
use AnyEvent::Loop;

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

	# $self->{DEBUG} = 1;

	$self->{MQTT}     = $mqtt;
	$self->{CONFIG}   = {};
	$self->{STATE}    = {};
	$self->{TIMERS}   = {};
	$self->{TIMEOUTS} = {};

	$self->setupSceneSubscriptions();

	return $self;
}

##
# Set up the listeners for scene subscribed topics
sub setupSceneSubscriptions {
	our ($self) = @ARG;

	$self->{MQTT}->subscribe(
		topic    => 'scene/+/timeout',   # 0 = closed, 1 = open, 0.5 = half open
		callback => sub {
			my ( $topic, $message ) = @ARG;
			$self->setSceneTimeout( $topic, $message );
		}
	);
	$self->debug("Subscribed to 'scene/+/timeout'");

	$self->{MQTT}->subscribe(
		topic    => 'scene/+/state',     # 0 = closed, 1 = open, 0.5 = half open
		callback => sub {
			my ( $topic, $message ) = @ARG;
			$self->setSceneState( $topic, $message );
		}
	);
	$self->debug("Subscribed to 'scene/+/state'");

}

##
# Set the timeout for a scene
# @param topic	the MQTT topic
# @param message the MQTT message Floating point value in seconds for the duration that a scene can remain active
sub setSceneTimeout {
	my ( $self, $topic, $message ) = @ARG;

	$topic =~ /scene\/(.+)\/timeout/
	  or return;

	my $device = $1;

	$self->{TIMEOUTS}->{$device} = $message;

	$self->debug("Set timeout for scene '$device' to '$message'");
}

##
# Change the state of a scene
# @param topic	the MQTT topic
# @param message the MQTT message 1 to activate the scene, 0 to deactivate it
sub setSceneState {
	my ( $self, $topic, $message ) = @ARG;

	$topic =~ /scene\/(.+)\/state/
	  or return;

	my $device = $1;

	$self->debug("Set scene '$device' to '$message'");

	if ( defined $self->{TIMERS}->{$device} ) {
		delete $self->{TIMERS}->{$device};
	}

	my $cv = $self->{MQTT}->publish(
		topic   => "scene/$device/active",
		message => $message,
	);
	push @{ $self->{CVS} }, $cv;

	return unless $message;

	if ( defined $self->{TIMEOUTS}->{$device} ) {
		$self->debug("Scheduling scene deactivation of '$device' for '$self->{TIMEOUTS}->{$device}' seconds");

		$self->{TIMERS}->{$device} = AnyEvent->timer(
			after => $self->{TIMEOUTS}->{$device},
			cv    => $cv,
			cb    => sub {
				$self->debug("Set scene '$device' to '0'");
				$self->{MQTT}->publish(
					topic   => "shutter/$device/active",
					message => 0,
					cv      => $cv,
				);
			},
		);
	}
}

1;

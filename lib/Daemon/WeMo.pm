package Daemon::WeMo;

use strict;
use warnings;
use English;
use Sys::Syslog qw(:standard :macros);

use AnyEvent;
use AnyEvent::MQTT;
use AnyEvent::Loop;

use WebService::Belkin::WeMo::Discover;
use WebService::Belkin::WeMo::Device;

use base 'Daemon';

##
# Create a new OneWire daemon
# @param class the class of this object
# @param generalConfig the general configuration
# @param wemoConfig the WeMo configuration
# @param mqttConfig the MQTT config (hashref)
sub new {
	my ( $class, $generalConfig, $wemoConfig, $mqttConfig ) = @ARG;

	my $self = $class->SUPER::new($generalConfig);
	bless $self, $class;

	$self->{MQTT_CONFIG}   = $mqttConfig;
	$self->{SWITCH_PERIOD} = $wemoConfig->{switch_period} // 5;
	$self->{DEBUG}         = $wemoConfig->{debug};

	return $self;
}

##
# Run WeMo in a new process to avoid delaying other event driven activities
sub run {
	my ($self) = @ARG;

	my $pid = fork();
	if ($pid) {
		return $pid;
	}

	$self->{MQTT_CONFIG}->{client_id} = 'HomeAutomation WeMo daemon';
	$self->{MQTT} = new AnyEvent::MQTT( %{ $self->{MQTT_CONFIG} } );

	$self->{DISCOVER} = new WebService::Belkin::WeMo::Discover();

	# Set up caches
	$self->{DEVICES}      = {};
	$self->{SWITCH_CACHE} = {};

	# List of pending tasks
	$self->{CVS} = [];

	$self->refreshDeviceCache();

	# Set up listeners
	$self->setupSwitchSubscriptions();
	$self->setupRefreshDeviceCache();

	# Kick off tasks
	$self->setupCVCleanup();
	$self->setupReadSwitchDevices();

	AnyEvent::Loop::run;
}

##
# Set up a timer to read the switches periodically
sub setupReadSwitchDevices {
	my ($self) = @ARG;

	$self->{READ_SWITCHES_TIMER} = AnyEvent->timer(
		after    => 0,
		interval => $self->{SWITCH_PERIOD},
		cb       => sub {
			$self->readSwitchDevices();
		}
	);
}

##
# Read all switch devices and push them to MQTT
sub readSwitchDevices {
	my ($self) = @ARG;

	my $cv = AnyEvent->condvar;

	foreach my $name ( keys %{ $self->{DEVICES}->{switch} } ) {
		my $device = $self->{DEVICES}->{switch}->{$name};

		$self->debug("Wemo '$name' check");
		my $state = $device->isSwitchOn();
		$self->debug("Wemo '$name' = '$state'");

		if ( ( $self->{SWITCH_CACHE}->{$name} // -1 ) != $state ) {
			$self->{SWITCH_CACHE}->{$name} = $state;
			$self->{MQTT}->publish(
				topic   => "switches/WeMo.${name}/toggle",
				message => 1,
				cv      => $cv,
			);

			my $topic = "switches/WeMo.${name}/state";
			$self->debug("Publish: '$topic'='$state'");

			$self->{MQTT}->publish(
				topic   => $topic,
				message => $state,
				retain  => 1,
				cv      => $cv,
			);
		}
	}

	push @{ $self->{CVS} }, $cv;
}

##
# Set up the device cache refresh
sub setupRefreshDeviceCache {
	my ($self) = @ARG;

	$self->{MQTT}->subscribe(
		topic    => 'control/wemo/scan',
		callback => sub {
			my ( $topic, $message ) = @ARG;
			$self->refreshDeviceCache();
		}
	);
}

##
# Refresh the device cache
sub refreshDeviceCache {
	my ($self) = @ARG;

	$self->debug('refreshing WeMo devices');

	$self->{DEVICES}           = {};
	$self->{DEVICES}->{switch} = {};
	$self->{DEVICES}->{sensor} = {};

	my $discovered = $self->{DISCOVER}->search();
	$self->{DISCOVER}->save('wemo.db');

	foreach my $ip ( keys %{$discovered} ) {
		my $device = $discovered->{$ip};

		$self->debug(
			"Found WeMo $device->{type} '$device->{name}' at '$device->{ip}'");
		$self->{DEVICES}->{ $device->{type} }->{ $device->{name} } =
		  new WebService::Belkin::WeMo::Device(
			ip => $device->{ip},
			db => 'wemo.db'
		  );
	}

	$self->debug('done refreshing WeMo devices');
}

##
# Set up the listeners for switch subscribed topics
sub setupSwitchSubscriptions {
	my ($self) = @ARG;
	$self->{MQTT}->subscribe(
		topic    => 'onoff/+/state',
		callback => sub {
			my ( $topic, $message ) = @ARG;
			$self->setGpioState( $topic, $message );
		}
	);

	$self->{MQTT}->subscribe(
		topic    => 'onoff/+/toggle',
		callback => sub {
			my ( $topic, $message ) = @ARG;
			$self->toggleGpioState($topic);
		}
	);
}

##
# Set the state of an output GPIO
# @param topic the MQTT topic ('onoff/<device>/state')
# @param message the MQTT message (0 or 1)
sub setGpioState {
	my ( $self, $topic, $message ) = @ARG;

	$topic =~ /onoff\/WeMo\.(.+)\/state/ or return;
	my $device = $1;

	if ($message) {
		$self->{SWITCH_CACHE}->{$device} = 1;
		$self->{DEVICES}->{switch}->{$device}->on();
	} else {
		$self->{SWITCH_CACHE}->{$device} = 0;
		$self->{DEVICES}->{switch}->{$device}->off();
	}
}

##
# Toggle the state of an output GPIO
# @param topic the MQTT topic ('onoff/<device>/state')
# @param message the MQTT message (0 or 1)
sub toggleGpioState {
	my ( $self, $topic ) = @ARG;

	$topic =~ /onoff\/WeMo\.(.+)\/toggle/ or return;
	my $device = $1;

	$self->{DEVICES}->{switch}->{$device}->toggle();

	my $cv = $self->{MQTT}->publish(
		topic   => "onoff/WeMo.$device/state",
		message => $self->{DEVICES}->{switch}->{$device}->isSwitchOn(),
		retain => 1,
	);
	push @{ $self->{CVS} }, $cv;
}

1;

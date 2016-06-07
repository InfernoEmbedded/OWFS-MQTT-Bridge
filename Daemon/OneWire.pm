package Daemon::OneWire;

use strict;
use warnings;
use English;
use Sys::Syslog qw(:standard :macros);
use threads;
use threads::shared;
use Thread::Semaphore;

use AnyEvent;
use AnyEvent::MQTT;
use AnyEvent::OWNet;

my $owLock : shared;

##
# Create a new OneWire daemon
# @param class the class of this object
# @param oneWireConfig the one wire configuration
# @param mqtt the MQTT instance
sub new {
	my ( $class, $oneWireConfig, $mqtt ) = @ARG;

	my $self = {};
	bless $self, $class;

	$self->{ONEWIRE_CONFIG} = $oneWireConfig;
	$self->{SENSOR_PERIOD}  = $oneWireConfig->{sensor_period} // 30;
	$self->{SWITCH_PERIOD}  = $oneWireConfig->{switch_period} // 0.05;

	$self->{MQTT} = $mqtt;

	# Set up caches
	$self->{SWITCH_CACHE}      = {};
	$self->{GPIO_CACHE}        = {};
	$self->{TEMPERATURE_CACHE} = {};

	$self->connect();

	# Set up listeners
	$self->setupSwitchSubscriptions();

	# Kick off tasks
	$self->setupSimultaneousRead();
	$self->setupReadSwitchDevices();

	return $self;
}

##
# Set up the simultaneous temperature read
sub setupSimultaneousRead {
	my ($self) = @ARG;

	$self->{SIMULTANEOUS_TEMPERATURE_TIMER} = AnyEvent->timer(
		after    => 0,
		interval => $self->{SENSOR_PERIOD},
		cb       => sub {
			$self->{OWFS}->write( '/simultaneous/temperature', "1\n" );

			# Schedule a read in 800 ms (at least 750ms needed for the devices to perform the read)
			$self->{READ_TEMPERATURE_TIMER} = AnyEvent->timer(
				after => 0.8,
				cb    => sub {
					$self->readTemperatureDevices();
				}
			);
		}
	);
}

my %temperatureFamilies = (
	'10' => 1,
	'21' => 1,
	'22' => 1,
	'26' => 1,
	'28' => 1,
	'3B' => 1,
	'7E' => 1,
);

##
# Read all temperature devices and push them to MQTT
sub readTemperatureDevices {
	my ($self) = @ARG;

	my $cv;
	$cv = $self->{OWFS}->devices(
		sub {
			my ($dev) = @ARG;
			$dev = substr( $dev, 1 );

			$cv->begin();

			my $family = substr( $dev, 0, 2 );
			return unless defined $temperatureFamilies{$family};

			$self->{OWFS}->get(
				$dev . 'temperature',
				sub {
					my ($res) = @ARG;
					$cv->end();

					my $value = $res->{data};
					return unless defined $value;

					$value =~ s/ *//;

					return
					  if ( defined $self->{TEMPERATURE_CACHE}->{$dev}
						&& $self->{TEMPERATURE_CACHE}->{$dev} == $value );
					$self->{TEMPERATURE_CACHE}->{$dev} = $value;

					#warn "Publish: 'sensors/temperature/${dev}temperature'='$value'";

					my $mqttCv = $self->{MQTT}->publish(
						topic   => "sensors/temperature/${dev}temperature",
						message => $value,
						retain  => 1,
					);
					$mqttCv->recv();
				}
			);
		}
	);
}

##
# Connect to the server
sub connect {
	my ($self) = @ARG;

	syslog( LOG_INFO, "Connecting to owserver" );
	my %ownetArgs = %{ $self->{ONEWIRE_CONFIG} };
	$ownetArgs{on_error} = sub {
		syslog( LOG_ERR, "Connection to owserver failed: " . join( ' ', @ARG ) );
	};

	$self->{OWFS} = AnyEvent::OWNet->new(%ownetArgs);
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

my %switchFamilies = (
	'05' => 1,
	'12' => 1,
	'1C' => 1,
	'1F' => 1,
	'29' => 1,
	'3A' => 1,
	'42' => 1,
);

##
# Read all switch devices and push them to MQTT
sub readSwitchDevices {
	my ($self) = @ARG;

	my $cv;
	$cv = $self->{OWFS}->devices(
		sub {
			my ($dev) = @ARG;
			$dev = substr( $dev, 1 );

			$cv->begin();

			my $family = substr( $dev, 0, 2 );
			return unless defined $switchFamilies{$family};

			$self->{OWFS}->get(
				"/uncached/${dev}sensed.ALL",
				sub {
					my ($res) = @ARG;
					$cv->end();

					my $value = $res->{data};
					return unless ( defined $value );

					my $deviceName = substr( $dev, 0, -1 );
					my (@bits) = split /,/, $value;

					# Send the state to MQTT if it has changed
					for ( my $gpio = 0 ; $gpio < @bits ; $gpio++ ) {
						my $dev   = "$deviceName.$gpio";
						my $topic = "switches/${dev}/state";
						my $state = $bits[$gpio];
						if ( ( $self->{SWITCH_CACHE}->{$topic} // -1 ) != $state ) {
							if ( defined $self->{SWITCH_CACHE}->{$topic} ) {
								my $mqttCv = $self->{MQTT}->publish(
									topic   => "switches/${dev}/toggle",
									message => 1,
								);
								$mqttCv->recv();
							}

							#warn "Publish: '$topic'='$state'";

							my $mqttCv = $self->{MQTT}->publish(
								topic   => $topic,
								message => $state,
								retain  => 1,
							);
							$mqttCv->recv();
						}
						$self->{SWITCH_CACHE}->{$topic} = $state;

					}
				}
			);
		}
	);
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
# Set the state of an output GPIO
# @param topic the MQTT topic ('onoff/<device>/state')
# @param message the MQTT message (0 or 1)
sub setGpioState {
	my ( $self, $topic, $message ) = @ARG;

	$topic =~ /onoff\/(.+)\.(\d)\/state/ or do {
		warn "unrecogised topic '$topic'";
		return;
	};
	my $device = $1;
	my $gpio   = $2;
	$message = $message ? 1 : 0;
	my $path = "/${device}/PIO.${gpio}";

	$self->{GPIO_CACHE}->{$path} = $message;

	$self->{OWFS}->write( $path, "$message\n" );
}

##
# Toggle the state of an output GPIO
# @param topic the MQTT topic ('onoff/<device>/state')
# @param message the MQTT message (0 or 1)
sub toggleGpioState {
	my ( $self, $topic ) = @ARG;

	$topic =~ /onoff\/(.+)\.(\d)\/toggle/ or do {
		warn "unrecogised topic '$topic'";
		return;
	};
	my $device = $1;
	my $gpio   = $2;
	my $path   = "/${device}/PIO.${gpio}";

	if ( !defined $self->{GPIO_CACHE}->{$path} ) {
		my $cv = $self->{OWFS}->("/uncached/${device}/PIO.${gpio}", sub {$self->{GPIO_CACHE}->{$path} = $ARG[0]});
		$cv->recv();
	}

	my $state = $self->{GPIO_CACHE}->{$path} ? '0' : '1';

	my $mqttCv = $self->{MQTT}->publish(
		topic   => "onoff/${device}.${gpio}/state",
		message => $state,
		retain  => 1,
	);
	$mqttCv->recv();
}

1;

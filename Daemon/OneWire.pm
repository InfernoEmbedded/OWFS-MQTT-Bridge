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
	$self->{DEVICES}           = {};

	# List of pending tasks
	$self->{CVS} = [];

	$self->connect();
	$self->refreshDeviceCache();

	# Set up listeners
	$self->setupSwitchSubscriptions();

	# Kick off tasks
	$self->setupSimultaneousRead();
	$self->setupReadSwitchDevices();
	$self->setupCVCleanup();
	$self->setupRefreshDeviceCache();

	return $self;
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

my @temperatureFamilies = ( '10', '21', '22', '26', '28', '3B', '7E' );

##
# Read all temperature devices and push them to MQTT
sub readTemperatureDevices {
	my ($self) = @ARG;

	my $cv = AnyEvent->condvar;

	foreach my $family (@temperatureFamilies) {

		#warn "Reading temperatures, family='$family'";
		next unless defined $self->{DEVICES}->{$family};

		my @devices = @{ $self->{DEVICES}->{$family} };
		foreach my $device (@devices) {

			#warn "Reading temperature for device '$device'";
			$self->{OWFS}->read(
				$device . 'temperature',
				sub {
					my ($res) = @ARG;

					$cv->begin();

					my $value = $res->{data};
					return unless defined $value;

					$value =~ s/ *//;

					#warn "Temperature = '$value'";
					return
					  if ( defined $self->{TEMPERATURE_CACHE}->{$device}
						&& $self->{TEMPERATURE_CACHE}->{$device} == $value );
					$self->{TEMPERATURE_CACHE}->{$device} = $value;

					$self->{MQTT}->publish(
						topic   => "sensors/temperature/${device}temperature",
						message => $value,
						retain  => 1,
						cv      => $cv,
					);
					$cv->end();
				}
			);
		}
	}

	push @{ $self->{CVS} }, $cv;
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
# Set up the device cache refresh
sub setupRefreshDeviceCache {
	my ($self) = @ARG;

	$self->{REFRESH_DEVICE_CACHE_TIMER} = AnyEvent->timer(
		after    => 0,
		interval => 60,
		cb       => sub {
			$self->refreshDeviceCache();
		}
	);
}

##
# Refresh the device cache
sub refreshDeviceCache {
	my ($self) = @ARG;

	$self->{DEVICES} = {};

	my $cv = $self->{OWFS}->devices(
		sub {
			my ($dev) = @ARG;
			$dev = substr( $dev, 1 );
			my $family = substr( $dev, 0, 2 );

			if ( !defined $self->{DEVICES}->{$family} ) {
				$self->{DEVICES}->{$family} = [];
			}

			push @{ $self->{DEVICES}->{$family} }, $dev;
		}
	);

	# Block here, we can't have anything else reading the device cache until we're done
	$cv->recv();
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

my @switchFamilies = ( '05', '12', '1C', '1F', '29', '3A', '42' );

##
# Read all switch devices and push them to MQTT
sub readSwitchDevices {
	my ($self) = @ARG;

	my $cv = AnyEvent->condvar;

	foreach my $family (@switchFamilies) {

		#warn "Reading switches for family '$family'";

		next unless defined $self->{DEVICES}->{$family};
		my @devices = @{ $self->{DEVICES}->{$family} };
		foreach my $device (@devices) {

			#warn "Reading switches for device '$device'";

			$self->{OWFS}->read(
				"/uncached/${device}sensed.ALL",
				sub {
					my ($res) = @ARG;
					my $value = $res->{data};
					return unless defined $value;

					$cv->begin();

					my $deviceName = substr( $device, 0, -1 );
					my (@bits) = split /,/, $value;

					# Send the state to MQTT if it has changed
					for ( my $gpio = 0 ; $gpio < @bits ; $gpio++ ) {
						my $dev   = "$deviceName.$gpio";
						my $topic = "switches/${dev}/state";
						my $state = $bits[$gpio];
						if ( ( $self->{SWITCH_CACHE}->{$topic} // -1 ) != $state ) {
							if ( defined $self->{SWITCH_CACHE}->{$topic} ) {
								$self->{MQTT}->publish(
									topic   => "switches/${dev}/toggle",
									message => 1,
									cv      => $cv,
								);
							}

							#warn "Publish: '$topic'='$state'";

							$self->{MQTT}->publish(
								topic   => $topic,
								message => $state,
								retain  => 1,
								cv      => $cv,
							);
						}
						$self->{SWITCH_CACHE}->{$topic} = $state;
					}

					$cv->end();
				}
			);
		}
	}

	push @{ $self->{CVS} }, $cv;
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

	#warn "Set '$path' to '$message'";

	my $cv = $self->{OWFS}->write( $path, "$message\n" );
	push @{ $self->{CVS} }, $cv;
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
		my $cv = $self->{OWFS}->read( "/uncached/${device}/PIO.${gpio}", sub { $self->{GPIO_CACHE}->{$path} = $ARG[0]; } );
		$cv->recv();
	}

	my $state = $self->{GPIO_CACHE}->{$path} ? '0' : '1';

	my $cv = $self->{MQTT}->publish(
		topic   => "onoff/${device}.${gpio}/state",
		message => $state,
		retain  => 1,
	);
	push @{ $self->{CVS} }, $cv;
}

1;

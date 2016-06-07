package Daemon::OneWire;

use strict;
use warnings;
use English;
use Sys::Syslog qw(:standard :macros);
use threads;
use threads::shared;
use Thread::Semaphore;
use Time::HiRes qw(usleep nanosleep);
use Net::MQTT::Simple;

use OW;

my $owLock :shared;

##
# Create a new OneWire daemon
# @param class the class of this object
# @param oneWireConfig the one wire configuration
# @param mqttConfig the MQTT configuration
sub new {
	my ($class, $oneWireConfig, $mqttConfig) = @ARG;

	my $self = {};
	bless $self, $class;

	$self->{SERVER} = $oneWireConfig->{server};
	$self->{SENSOR_PERIOD} = $oneWireConfig->{sensor_period} // 60 * 1000;
	$self->{SWITCH_PERIOD} = $oneWireConfig->{switch_period} // 100;

	$self->{MQTT_CONFIG} = $mqttConfig;

	$self->connect();

	return $self;
}

##
# Connect to the server
sub connect {
	my ($self) = @ARG;

	syslog(LOG_INFO, "Connecting to owserver '$self->{SERVER}'");
	OW::init($self->{SERVER});
	syslog(LOG_ERR, "Connection to owserver '$self->{SERVER}' failed") unless defined $self->{owfs};
}

##
# Refresh the device list
# @post $self->{DEVICES} contains a list of the devices
sub refreshDevices {
	my ($self) = @ARG;

	my $dir;
	{
		lock($owLock);
		$dir = OW::get('/');
	}

	my @dir = split /,/, $dir;
	$self->{DEVICES} = \@dir;
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
# Sensor action
# Request a simultaneous read of the temperature sensors, then gather the data
sub sensorAction {
	my ($self) = @ARG;

	{
		lock($owLock);

		OW::put('/simultaneous/temperature', "1\n");
	}

	usleep(800 * 1000);

	$self->refreshDevices();

	foreach my $device (@{$self->{DEVICES}}) { # device includes trailing '/'
		my $family = substr($device, 0, 2);
		if ($temperatureFamilies{$family}) {
			my $temperature;
			{
				lock($owLock);
				$temperature = OW::get($device . 'temperature') or do {
					warn "Could not read temperature from '$device'";
					next;
				}
			}
			$self->{MQTT}->retain("sensors/temperature/${device}temperature", $temperature);
		}
	}
}

##
# Run the sensor thread
sub sensorThread {
	my ($self) = @ARG;

	{
		no strict 'refs';
		no warnings 'redefine';
		*Net::MQTT::Simple::_client_identifier = sub { "1WireSensors[$$]" };

		$self->{MQTT} = new Net::MQTT::Simple($self->{MQTT_CONFIG}->{'server'}) or
			die "Could not connect to MQTT server '$self->{MQTT_CONFIG}->{server}'";
	}

	while (1) {
		$self->sensorAction();
		usleep($self->{SENSOR_PERIOD});
	}
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

my %switchCache;

##
# Switch action
# Read the states of GPIO
# Check for incoming MQTT messages
sub switchAction {
	my ($self) = @ARG;

	foreach my $device (@{$self->{DEVICES}}) { # device includes trailing '/'
		my $family = substr($device, 0, 2);
		if ($switchFamilies{$family}) {
			my $sensed;
			{
				lock($owLock);
				$sensed = OW::get("/uncached/${device}sensed.ALL") or do {
					warn "Could not read IO state from '$device'";
					next;
				}
			}

			my $deviceName = substr($device, 0, -1);
			my (@bits) = split /,/, $sensed;

			# Send the state to MQTT if it has changed
			for (my $gpio = 0; $gpio < @bits; $gpio++) {
				my $dev = "$deviceName.$gpio";
				my $topic = "switches/${dev}/state";
				my $state = $bits[$gpio];
				if (($switchCache{$topic} // -1) != $state) {
					if (defined $switchCache{$topic}) {
						$self->{MQTT}->publish("switches/${dev}/toggle", 1);
					}
					$self->{MQTT}->retain($topic, $state);
					$switchCache{$topic} = $state;
				}
			}
		}
	}

	$self->{MQTT}->tick();
}

my %gpioCache;

##
# Set the state of an output GPIO
# @param topic the MQTT topic ('onoff/<device>/state')
# @param message the MQTT message (0 or 1)
sub setGpioState {
	my ($self, $topic, $message) = @ARG;

	$topic =~ /onoff\/(.+)\.(\d)\/state/ or do {
		warn "unrecogised topic '$topic'";
		return;
	};
	my $device = $1;
	my $gpio = $2;
	$message = $message ? 1 : 0;
	my $path = "/${device}/PIO.${gpio}";

	$gpioCache{$path} = $message;

	{
		lock($owLock);
		OW::put($path, "$message\n");
	}
}

##
# Toggle the state of an output GPIO
# @param topic the MQTT topic ('onoff/<device>/state')
# @param message the MQTT message (0 or 1)
sub toggleGpioState {
	my ($self, $topic) = @ARG;

	$topic =~ /onoff\/(.+)\.(\d)\/toggle/ or do {
		warn "unrecogised topic '$topic'";
		return;
	};
	my $device = $1;
	my $gpio = $2;
	my $path = "/${device}/PIO.${gpio}";

	if (!defined $gpioCache{$path}) {
		lock($owLock);
		$gpioCache{$path} = OW::get("/uncached/${device}/PIO.${gpio}");
	}

	my $state = $gpioCache{$path} ? '0' : '1';
	$self->{MQTT}->retain("onoff/${device}.${gpio}/state", $state);
}


##
# Switch thread init
sub switchThreadInit {
	my ($self) = @ARG;

	{
		no strict 'refs';
		no warnings 'redefine';
		*Net::MQTT::Simple::_client_identifier = sub { "1WireSwitches[$$]" };

		$self->{MQTT} = new Net::MQTT::Simple($self->{MQTT_CONFIG}->{'server'}) or
			die "Could not connect to MQTT server '$self->{MQTT_CONFIG}->{server}'";
	}

	$self->refreshDevices();

	# Keep the cache updated
	$self->{MQTT}->subscribe(
		'switches/+/state' => sub {
			my ($topic, $message) = @ARG;
			$switchCache{$topic} = $message;
		},
		'onoff/+/state' => sub {
			my ($topic, $message) = @ARG;
			$self->setGpioState($topic, $message);
		},
		'onoff/+/toggle' => sub {
			my ($topic, $message) = @ARG;
			$self->toggleGpioState($topic);
		},
	);

	# Give mqtt a chance to update the cache
	$self->{MQTT}->tick(5);

	# Take the devices out of test mode
	foreach my $device (@{$self->{DEVICES}}) { # device includes trailing '/'
		lock($owLock);
		OW::put("${device}out_of_testmode", "1\n");
	}

	# We will maintain the cache internally from now on
	$self->{MQTT}->unsubscribe('switches/+/state');
}

##
# Run the switch thread
sub switchThread {
	my ($self) = @ARG;

	$self->switchThreadInit();

	my $count = 0;

	while (1) {
		if (0 == $count % 600) { # Refresh devices every minute, for a 100ms poll period
			$self->refreshDevices();
		}

		$self->switchAction();
		usleep($self->{SWITCH_PERIOD});
		$count++;
	}
}


##
# Launch all threads
sub run {
	my ($self) = @ARG;

    $self->{SENSOR_THREAD} = threads->create('sensorThread', $self) or
    	die "Could not launch sensor thread";

    $self->{SWITCH_THREAD} = threads->create('switchThread', $self) or
    	die "Could not launch switch thread";

    return (
    	'1Wire Sensors' => $self->{SENSOR_THREAD},
    	'1Wire Switches' => $self->{SWITCH_THREAD},
    );
}

END {
	OW::finish();
}

1;
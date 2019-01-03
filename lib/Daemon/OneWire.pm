package Daemon::OneWire;

use strict;
use warnings;
use English;

use AnyEvent;
use AnyEvent::MQTT;
use AnyEvent::OWNet;

use base 'Daemon';
use experimental;

##
# Create a new OneWire daemon
# @param class the class of this object
# @param oneWireConfig the one wire configuration
# @param mqtt the MQTT instance
sub new {
	my ( $class, $generalConfig, $oneWireConfig, $mqtt ) = @ARG;

	my $self = $class->SUPER::new($generalConfig);
	bless $self, $class;

	$self->{ONEWIRE_CONFIG} = $oneWireConfig;
	$self->{SENSOR_PERIOD}  = $oneWireConfig->{sensor_period} // 30;
	$self->{SWITCH_PERIOD}  = $oneWireConfig->{switch_period} // 0.05;
	$self->{REFRESH_PERIOD}  = $oneWireConfig->{refresh_period} // 120;
	$self->{DEBUG}          = $oneWireConfig->{debug};

	$self->debug("OneWire started, switch period='$self->{SWITCH_PERIOD}' sensor period='$self->{SENSOR_PERIOD}'");

	$self->{MQTT} = $mqtt;

	# Set up caches
	$self->{SWITCH_CACHE}      = {};
	$self->{SWITCH_MASTER_CACHE} = {};
	$self->{GPIO_CACHE}        = {};
	$self->{TEMPERATURE_CACHE} = {};
	$self->{DEVICES}           = {};
	$self->{REGISTER_CACHE}    = {};

	$self->connect();
	$self->setupRefreshDeviceCache();

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

my @temperatureFamilies = ( '10', '21', '22', '26', '28', '3B', '7E' );
my %temperatureFamilies;
foreach my $family (@temperatureFamilies) {
	$temperatureFamilies{$family} = 1;
}

##
# Read all temperature devices and push them to MQTT
sub readTemperatureDevices {
	my ($self) = @ARG;

	my $cv = AnyEvent->condvar;

	foreach my $family (@temperatureFamilies) {

		#$self->debug("Reading temperatures, family='$family'");
		next unless defined $self->{DEVICES}->{$family};

		my @devices = @{ $self->{DEVICES}->{$family} };
		foreach my $device (@devices) {

			#$self->debug("Reading temperature for device '$device'");
			$self->{OWFS}->read(
				$device . 'temperature',
				sub {
					my ($res) = @ARG;

					$cv->begin();

					my $value = $res->{data};
					return unless defined $value;

					$value =~ s/ *//;

					return
					  if ( defined $self->{TEMPERATURE_CACHE}->{$device}
						&& $self->{TEMPERATURE_CACHE}->{$device} == $value );
					$self->{TEMPERATURE_CACHE}->{$device} = $value;

					my $topic = "temperature/${device}/state";

					$self->{MQTT}->publish(
						topic   => $topic,
						message => $value,
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

	$self->log("Connecting to owserver");
	my %ownetArgs = %{ $self->{ONEWIRE_CONFIG} };
	$ownetArgs{on_error} = sub {
		$self->logError(
			"Connection to owserver failed: " . join( ' ', @ARG ) );
	};

	$self->{OWFS} = AnyEvent::OWNet->new(%ownetArgs);
}

##
# Set up the device cache refresh
sub setupRefreshDeviceCache {
	my ($self) = @ARG;

	$self->{REFRESH_DEVICE_CACHE_TIMER} = AnyEvent->timer(
		after    => 0,
		interval => $self->{REFRESH_PERIOD},
		cb       => sub {
			$self->refreshDeviceCache();
		}
	);
}

##
# Register switch master switches with HomeAssistant MQTT discovery
# @param device the device address
# @param ports the number of ports
# @param channels the number of channels
sub registerSwitchMasterSwitches {
	my ($self, $device, $ports, $channels) = @ARG;

	if (defined ($self->{REGISTER_CACHE}->{$device}->{REGISTERED_MQTT_DISCOVERY_SWITCHES})) {
		return;
	}

	$self->{REGISTER_CACHE}->{$device}->{REGISTERED_MQTT_DISCOVERY_SWITCHES} = 1;

	for (my $port = 0; $port < $ports; $port++) {
		for (my $channel = 0; $channel < $channels; $channel++) {
			my $topic = $self->{GENERAL_CONFIG}->{discovery_prefix} . "/binary_sensor/button_${device}_${port}_${channel}/config";
			$topic =~ s/\.//;

			my $message = <<EOF;
{
	"name": "button_${device}_${port}_${channel}",
	"state_topic": "switches/$device/$port/$channel/activated"
}
EOF

			my $cv = $self->{MQTT}->publish(
				topic   => $topic,
				message => $message,
				retain	=> 1,
			);
			push @{ $self->{CVS} }, $cv;
		}
	}
}

##
# Register switch master relays with HomeAssistant MQTT discovery
# @param device the device address
# @param ports the number of ports
# @param channels the number of channels
sub registerSwitchMasterRelays {
	my ($self, $device, $ports, $channels) = @ARG;

	if (defined ($self->{REGISTER_CACHE}->{$device}->{REGISTERED_MQTT_DISCOVERY_RELAYS})) {
		return;
	}

	$self->{REGISTER_CACHE}->{$device}->{REGISTERED_MQTT_DISCOVERY_RELAYS} = 1;

	for (my $port = 0; $port < $ports; $port++) {
		for (my $channel = 0; $channel < $channels; $channel++) {
			my $topic = $self->{GENERAL_CONFIG}->{discovery_prefix} . "/switch/relay_${device}_${port}_${channel}/config";
			$topic =~ s/\.//;

			my $message = <<EOF;
{
	"name": "relay_${device}_${port}_${channel}",
	"command_topic": "relays/$device/$port/$channel/state",
	"state_topic": "relays/$device/$port/$channel/state"
}
EOF
			my $cv = $self->{MQTT}->publish(
				topic   => $topic,
				message => $message,
				retain	=> 1,
			);
			push @{ $self->{CVS} }, $cv;
		}
	}
}

##
# Register switch master LEDs with HomeAssistant MQTT discovery
# @param device the device address
# @param ports the number of ports
# @param channels the number of channels
sub registerSwitchMasterLeds {
	my ($self, $device, $ports, $channels) = @ARG;

	if (defined ($self->{REGISTER_CACHE}->{$device}->{REGISTERED_MQTT_DISCOVERY_LEDS})) {
		return;
	}

	$self->{REGISTER_CACHE}->{$device}->{REGISTERED_MQTT_DISCOVERY_LEDS} = 1;

	for (my $port = 0; $port < $ports; $port++) {
		for (my $channel = 0; $channel < $channels; $channel++) {
			my $topic = $self->{GENERAL_CONFIG}->{discovery_prefix} . "/switch/led_${device}_${port}_${channel}/config";
			$topic =~ s/\.//;

			my $message = <<EOF;
{
	"name": "led_${device}_${port}_${channel}",
	"command_topic": "leds/$device/$port/$channel/state",
	"state_topic": "leds/$device/$port/$channel/state",
}
EOF

			my $cv = $self->{MQTT}->publish(
				topic   => $topic,
				message => $message,
				retain	=> 1,
			);
			push @{ $self->{CVS} }, $cv;
		}
	}
}


##
# Refresh cache info for IE Switch master
# @param dev the address of the device
sub refreshIESwitchMaster {
	my ($self, $dev) = @ARG;

	$self->debug("Updating switch master '$dev'");

	$self->{SWITCHMASTER_CACHE}->{$dev}->{CHANNEL_CONFIG} //= [];

	$self->{OWFS}->read(
		"/${dev}/switch_channels",
		sub {
			my ($switchChannels) = $ARG[0]->data;
			$switchChannels =~ s/^\s+//;

			$self->debug("Found IE Switch Master at '$dev' with '$switchChannels' switch channels'");

			$self->{SWITCHMASTER_CACHE}->{$dev}->{SWITCH_CHANNELS} = $switchChannels;

			$self->{OWFS}->read(
				"/${dev}/switch_ports",
				sub {
					my ($switchPorts) = $ARG[0]->data;
					$switchPorts =~ s/^\s+//;

					$self->debug("Found IE Switch Master at '$dev' with '$switchPorts' switch ports'");

					$self->{SWITCHMASTER_CACHE}->{$dev}->{SWITCH_PORTS} = $switchPorts;

					$self->registerSwitchMasterSwitches($dev, $switchPorts, $switchChannels);
				}
			);
		}
	);

	$self->{OWFS}->read(
		"/${dev}/relay_channels",
		sub {
			my ($relayChannels) = $ARG[0]->data;
			$relayChannels =~ s/^\s+//;

			$self->debug("Found IE Switch Master at '$dev' with '$relayChannels' relay channels'");

			$self->{SWITCHMASTER_CACHE}->{$dev}->{RELAY_CHANNELS} = $relayChannels;

			$self->{OWFS}->read(
				"/${dev}/relay_ports",
				sub {
					my ($relayPorts) = $ARG[0]->data;
					$relayPorts =~ s/^\s+//;

					$self->debug("Found IE Switch Master at '$dev' with '$relayPorts' relay ports'");

					$self->{SWITCHMASTER_CACHE}->{$dev}->{RELAY_PORTS} = $relayPorts;

					$self->registerSwitchMasterRelays($dev, $relayPorts, $relayChannels);
				}
			);
		}
	);


	$self->{OWFS}->read(
		"/${dev}/led_channels",
		sub {
			my ($ledChannels) = $ARG[0]->data;
			$ledChannels =~ s/^\s+//;

			$self->debug("Found IE Switch Master at '$dev' with '$ledChannels' led channels'");

			$self->{SWITCHMASTER_CACHE}->{$dev}->{LED_CHANNELS} = $ledChannels;

			$self->{OWFS}->read(
				"/${dev}/led_ports",
				sub {
					my ($ledPorts) = $ARG[0]->data;
					$ledPorts =~ s/^\s+//;

					$self->debug("Found IE Switch Master at '$dev' with '$ledPorts' led ports'");

					$self->{SWITCHMASTER_CACHE}->{$dev}->{LED_PORTS} = $ledPorts;

					$self->registerSwitchMasterLeds($dev, $ledPorts, $ledChannels);
				}
			);
		}
	);

}

##
# Handle device refresh for IE devices
# @param dev the address of the device
# @param the family given by the 'device' entry in OWFS
sub refreshIEDeviceCache {
	my ($self, $dev, $family) = @ARG;

	$self->debug("Updating IE '$family' '$dev'");

	if ($family eq 'Inferno Embedded Switch Master') {
		$self->refreshIESwitchMaster($dev);
	}
}

##
# Register temperature devices with HomeAssistant MQTT discovery
# @param device the device address
sub registerTemperatureDevice {
	my ($self, $device) = @ARG;

	if (defined ($self->{REGISTER_CACHE}->{$device}->{REGISTERED_MQTT_DISCOVERY_TEMPERATURE})) {
		return;
	}

	$self->{REGISTER_CACHE}->{$device}->{REGISTERED_MQTT_DISCOVERY_TEMPERATURE} = 1;

	my $topic = $self->{GENERAL_CONFIG}->{discovery_prefix} . "/sensor/${device}_temperature/config";
	$topic =~ s/\.//;

			my $message = <<EOF;
{
	"name": "${device}_temperature",
	"current_temperature_topic": "temperature/$device/state",
	"unit_of_measurement": "°C"
}
EOF


	my $cv = $self->{MQTT}->publish(
		topic   => $topic,
		message => $message,
		retain	=> 1,
	);
	push @{ $self->{CVS} }, $cv;
}

##
# Refresh the device cache
sub refreshDeviceCache {
	my ($self) = @ARG;

	my %devices;

	my $cv = $self->{OWFS}->devices(
		sub {
			my ($dev) = @ARG;
			$dev = substr( $dev, 1, 15);
			my $family = substr( $dev, 0, 2 );

			$self->debug("Updating device cache for '$dev'");

			if ( $family eq 'ED' ) {
				$self->{OWFS}->read(
					"/${dev}/device",
					sub {
						my ($family) = $ARG[0]->data;
						$family =~ s/\x00+$//;

						$self->refreshIEDeviceCache($dev, $family);
					}
				);
			} else {
				if ( !defined $devices{$family} ) {
					$devices{$family} = [];
				}

				push @{ $devices{$family} }, $dev;

				if (defined($temperatureFamilies{$family})) {
					$self->registerTemperatureDevice($dev);
				}
			}
		}
	);

	$self->{DEVICES} = \%devices;
}

my %switchMasterSwitchTypes = (	'TOGGLE_PULL_DOWN'		=> 0,
								'TOGGLE_PULL_UP'		=> 1,
								'MOMENTARY_PULL_DOWN'	=> 2,
								'MOMENTARY_PULL_UP'		=> 3);

##
# Write a switch type out to the SwitchMaster device
# @param device the device to configure
# @param port the port to configure
# @param channel the channel to configure
# @parm type the type for that channel (TOGGLE_PULL_DOWN, TOGGLE_PULL_UP, MOMENTARY_PULL_DOWN, MOMENTARY_PULL_UP)
sub writeSwitchMasterChannelConfig {
	my ($self, $device, $port, $channel, $type) = @ARG;

	$type = $switchMasterSwitchTypes{$type};

	# Fixme
	$self->writePath("/uncached/$device/set_switch_type", "$port,$channel,$type\n");
}

##
# Parse MQTT messages to configure a SwitchMaster switch type
# @param topic the MQTT topic
# @param message the MQTT message
sub configureSwitchDevice {
	my ($self, $topic, $message) = @ARG;

	my @topicBits = split(/\//, $topic);
	my $dev = $topicBits[1];
	my $port = int($topicBits[2]);
	my $channel = int($topicBits[3]);
	if (not defined($switchMasterSwitchTypes{$message})) {
		$self->logError("Unrecognised type '$message' for device '$dev', port '$port, channel '$channel'");
		return;
	}
	my $type = $switchMasterSwitchTypes{$message};

	$self->{SWITCHMASTER_CACHE}->{$dev}->{CHANNEL_CONFIG}->[$port] //= [];
	$self->{SWITCHMASTER_CACHE}->{$dev}->{CHANNEL_CONFIG}->[$port]->[$channel] = $type;

	$self->writeSwitchMasterChannelConfig($dev, $port, $channel, $type);
}

##
# Write relay state out to a switch master device
# @param device the device to write to
# @param port the port to set state on
# @param channel the channel to set state on
# @param state the state to the channel to (on, off, 0-255)
sub writeSwitchMasterRelay {
	my ($self, $device, $port, $channel, $state) = @ARG;

	if (lc($state) eq 'on') {
		$state = 1;
	} elsif (lc($state) eq 'off') {
		$state = 0;
	} else {
		$state = int($state);
		$self->debug("State = '$state'");
		if ($state < 0 or $state > 255) {
			$self->logError("Relay state '$state' out of bounds for device '$device' port '$port' channel '$channel'");
			return;
		}
	}

	$self->{OWFS}->read(
		"/uncached/$device/relay_port${port}",
		sub {
			my $portVals = $ARG[0]->data;
			$portVals =~ s/\x00+$//;

			my @portBits = split /,/, $portVals;

			$portBits[$channel] = $state;
			$portVals = join(',', @portBits);

			$self->{OWFS}->write(
				"/uncached/$device/relay_port${port}",
				$portVals,
				sub {$self->debug("Wrote '$portVals' to 'uncached/$device/relay_port${port}'");}
			);
		}
	);
}

##
# Set the state of a relay on a switch master device
# @param topic the incoming MQTT topic
# @param message the incoming MQTT message
sub setSwitchMasterRelay {
	my ($self, $topic, $message) = @ARG;

	my @topicBits = split(/\//, $topic);
	my $dev = $topicBits[1];
	my $port = int($topicBits[2]);
	my $channel = int($topicBits[3]);

	$self->writeSwitchMasterRelay($dev, $port, $channel, $message);
}

##
# Write led state out to a switch master device
# @param device the device to write to
# @param port the port to set state on
# @param channel the channel to set state on
# @param state the state to the channel to (on, off, 0-1)
sub writeSwitchMasterLed {
	my ($self, $device, $port, $channel, $state) = @ARG;

	if (lc($state) eq 'on') {
		$state = 1;
	} elsif (lc($state) eq 'off') {
		$state = 0;
	} else {
		$state = int($state);
		$self->debug("State = '$state'");
		if ($state < 0 or $state > 1) {
			$self->logError("Led state '$state' out of bounds for device '$device' port '$port' channel '$channel'");
			return;
		}
	}

	$self->{OWFS}->read(
		"/uncached/$device/led_port${port}",
		sub {
			my $portVals = $ARG[0]->data;
			$portVals =~ s/\x00+$//;

			my @portBits = split /,/, $portVals;

			$portBits[$channel] = $state;
			$portVals = join(',', @portBits);

			$self->{OWFS}->write(
				"/uncached/$device/led_port${port}",
				$portVals,
				sub {$self->debug("Wrote '$portVals' to 'uncached/$device/led_port${port}'");}
			);
		}
	);
}

##
# Set the state of a led on a switch master device
# @param topic the incoming MQTT topic
# @param message the incoming MQTT message
sub setSwitchMasterLed {
	my ($self, $topic, $message) = @ARG;

	my @topicBits = split(/\//, $topic);
	my $dev = $topicBits[1];
	my $port = int($topicBits[2]);
	my $channel = int($topicBits[3]);

	$self->writeSwitchMasterLed($dev, $port, $channel, $message);
}


##
# Set up the listeners for switch subscribed topics
sub setupSwitchSubscriptions {
	my ($self) = @ARG;

	# Legacy 1wire device set state
	$self->{MQTT}->subscribe(
		topic    => 'onoff/+/+/state',
		callback => sub {
			my ( $topic, $message ) = @ARG;
			$self->setGpioState( $topic, $message );
		}
	);

	# Legacy 1wire device toggle
		$self->{MQTT}->subscribe(
		topic    => 'onoff/+/+/toggle',
		callback => sub {
			my ( $topic, $message ) = @ARG;
			$self->toggleGpioState($topic);
		}
	);

	# Switch Master switch configuration
	$self->{MQTT}->subscribe(
		# Wildcards: device, port, channel
		topic    => 'switches/+/+/+/configure',
		callback => sub {
			my ( $topic, $message ) = @ARG;
			$self->configureSwitchMasterSwitch($topic, $message);
		}
	);

	# Switch Master relay configuration
	$self->{MQTT}->subscribe(
		# Wildcards: device, port, channel
		topic    => 'relays/+/+/+/configure',
		callback => sub {
			my ( $topic, $message ) = @ARG;
			$self->configureSwitchMasterRelay($topic, $message);
		}
	);

	# Switch Master relay state
	$self->{MQTT}->subscribe(
		# Wildcards: device, port, channel
		topic    => 'relays/+/+/+/state',
		callback => sub {
			my ( $topic, $message ) = @ARG;
			$self->setSwitchMasterRelay($topic, $message);
		}
	);

	# Switch Master led state
	$self->{MQTT}->subscribe(
		# Wildcards: device, port, channel
		topic    => 'leds/+/+/+/state',
		callback => sub {
			my ( $topic, $message ) = @ARG;
			$self->setSwitchMasterLed($topic, $message);
		}
	);

}


my @legacySwitchFamilies = ( '05', '12', '1C', '1F', '29', '3A', '42' );

##
# Read legacy OWFS switches such as DS2408 & friends
# @param device the device name to read
# @param cv the condition var
sub readLegacySwitchDevice {
	my ($self, $device, $cv) = @ARG;

	#$self->debug("Reading switches for device '$device'");

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
				my $dev   = "$deviceName/$gpio";
				my $topic = "switches/${dev}/state";
				my $state = $bits[$gpio];
				if ( ( $self->{SWITCH_CACHE}->{$topic} // -1 ) != $state ) {
					if ( defined $self->{SWITCH_CACHE}->{$topic} ) {
						$self->{MQTT}->publish(
							topic   => "switches/{dev}/toggle",
							message => 1,
							cv      => $cv,
						);
					}

					$self->debug("Publish: '$topic'='$state'");

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

##
# Read switches on InfernoEmbedded SwitchMaster devices
# @param device the device name to read
# @param cv the condition var
sub readIESwitchDevice {
	my ($self, $device, $cv) = @ARG;

	if (!defined $self->{SWITCHMASTER_CACHE}->{$device}) {
		return;
	}

	$self->{OWFS}->write(
		"/uncached/${device}/switch_refresh_activations",
		"y\n",
		sub {
			for (my $port = 0; $port < $self->{SWITCHMASTER_CACHE}->{$device}->{SWITCH_PORTS}; $port++) {
				my $portCopy = $port;
				$cv->begin();

				my $portVal = $self->{OWFS}->read(
					"/${device}/switch_port${port}",
					sub {
						my ($portVal) = $ARG[0]->data;
						$portVal =~ s/\x00+$//;

						$self->debug("Read portval '$portVal' for switch port '$portCopy'");

						my @portActivations = split(/,/, $portVal);

						for (my $channel = 0; $channel < $self->{SWITCHMASTER_CACHE}->{$device}->{SWITCH_CHANNELS}; $channel++) {
							if (!$portActivations[$channel]) {
								next;
							}

							my $dev = "$device/$portCopy/$channel";
							my $topic = "switches/${dev}/activated";
							$self->{MQTT}->publish(
											topic   => $topic,
											message => 'ON',
											cv      => $cv,
							);

							$self->{MQTT}->publish(
											topic   => $topic,
											message => 'OFF',
											cv      => $cv,
							);
						}

						$cv->end();
					}
				);
			}
		}
	);
}

##
# Power on Reset handling for InfernoEmbedded Switch Master devices
sub powerOnResetSwitchMaster {
	my ($self, $device) = @ARG;

	$self->debug("Reconfiguring Switch Master '$device' due to power on reset");


	foreach my $port (@{$self->{SWITCHMASTER_CACHE}->{$device}->{CHANNEL_CONFIG}}) {
		foreach my $channel (@{$self->{SWITCHMASTER_CACHE}->{$device}->{CHANNEL_CONFIG}->[$port]}) {
			my $type = $self->{SWITCHMASTER_CACHE}->{$device}->{CHANNEL_CONFIG}->[$port]->[$channel];
			$self->writeSwitchMasterChannelConfig($device, $port, $channel, $type);
		}
	}
}

##
# Power on reset handling for InfernoEmbedded softdevices
# @param device the device address
sub powerOnResetIE {
	my ($self, $device) = @ARG;

	$self->debug("Poweron reset for Inferno Embedded device '$device'");

	$self->{OWFS}->read(
		"/${device}/device",
		sub {
			my ($family) = $ARG[0]->data;
			$family =~ s/\x00+$//;

			$self->debug("Power on reset for family '$family'");
			$self->refreshIEDeviceCache($device, $family);

			if ($family eq 'Inferno Embedded Switch Master') {
				$self->debug("Matched switch master");
				$self->powerOnResetSwitchMaster($device);
			} else {
				$self->debug("'$family' != 'Inferno Embedded Switch Master'");
				$self->debug("Family length=", length($family));
			}
		}
	);
}

##
# Read all switch devices and push them to MQTT
sub readSwitchDevices {
	my ($self) = @ARG;

	my $cv = AnyEvent->condvar;

	foreach my $family (@legacySwitchFamilies) {
		#$self->debug("Reading switches for family '$family'");

		next unless defined $self->{DEVICES}->{$family};
		my @devices = @{ $self->{DEVICES}->{$family} };
		foreach my $device (@devices) {
			$self->readLegacySwitchDevice($device, $cv);
		}
	}

	$self->{OWFS}->devices(
		sub {
			my ($dev) = @ARG;
			$dev = substr( $dev, 7, 15 );
			my $family = substr( $dev, 0, 2 );

			$self->debug("Found alarmed device '$dev' family='$family'");

			if ( $family eq 'ED' ) { # Inferno Embedded Softdevices
				$self->{OWFS}->read(
					"/uncached/${dev}/status",
					sub {
						my ($status) = int($ARG[0]->data);

						if ($status & 0x01) {
							# Power on reset
							$self->powerOnResetIE($dev);
						}

						if ($status & 0x02 and defined($self->{SWITCHMASTER_CACHE}->{$dev})) {
							$self->readIESwitchDevice($dev, $cv);
						}
					}
				);
			}
		},
		'/alarm/', $cv
	);

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

	$topic =~ /onoff\/(.+)\.(\d)\/state/ or return;
	my $device = $1;
	my $gpio   = $2;
	$message = $message ? 1 : 0;
	my $path = "/${device}/PIO.${gpio}";

	$self->{GPIO_CACHE}->{$path} = $message;

	#$self->debug("Set '$path' to '$message'");

	my $cv = $self->{OWFS}->write( $path, "$message\n" );
	push @{ $self->{CVS} }, $cv;
}

##
# Toggle the state of an output GPIO
# @param topic the MQTT topic ('onoff/<device>/state')
# @param message the MQTT message (0 or 1)
sub toggleGpioState {
	my ( $self, $topic ) = @ARG;

	$topic =~ /onoff\/(.+)\.(\d)\/toggle/ or return;
	my $device = $1;
	my $gpio   = $2;
	my $path   = "/${device}/PIO.${gpio}";

	if ( !defined $self->{GPIO_CACHE}->{$path} ) {
		my $cv = $self->{OWFS}->read( "/uncached/${device}/PIO.${gpio}",
			sub { $self->{GPIO_CACHE}->{$path} = $ARG[0]; } );
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

package Daemon::Logger;

use strict;
use warnings;
use English;

use AnyEvent;
use AnyEvent::MQTT;
use AnyEvent::Loop;

use aliased 'DBIx::Class::DeploymentHandler' => 'DH';
use DB::Schema;

use base 'Daemon';

##
# Create a new logger daemon
# @param class the class of this object
# @param generalConfig the general configuration
# @param dbConfig the database config
# @param mqttConfig the MQTT config (hashref)
sub new {
	my ( $class, $generalConfig, $dbConfig, $mqttConfig ) = @ARG;

	my $self = $class->SUPER::new($generalConfig);
	bless $self, $class;

	$self->{MQTT_CONFIG} = $mqttConfig;
	$self->{CONFIG} = $dbConfig;
	$self->connectDatabase($dbConfig);

	return $self;
}

##
# Connect to the database
sub connectDatabase {
	my ($self) = @ARG;

	$self->{DB} = DB::Schema->connect( $self->{CONFIG}->{dsn}, $self->{CONFIG}->{user}, $self->{CONFIG}->{password} );
}

##
# Install the database schema
sub installDatabase {
	my ( $self ) = @ARG;

	$self->{CONFIG}->{dsn} =~ /:(.+):/
	  or die "Could not extract DB type from DSN '$self->{CONFIG}->{dsn}'";
	my $dbType = $1;

	my $dh = DH->new(
		{
			schema              => $self->{DB},
			databases           => $dbType,
			sql_translator_args => { add_drop_table => 0, force_overwrite => 1 },
		}
	);

	$dh->prepare_install;
	$dh->install;
}

##
# Run the DB logging daemon in a new process
sub run {
	my ($self) = @ARG;

	my $pid = fork();
	if ($pid) {
		return $pid;
	}

	$self->{MQTT_CONFIG}->{client_id} = 'HomeAutomation logging daemon';

	$self->{MQTT} = new AnyEvent::MQTT(%{$self->{MQTT_CONFIG}});

	$self->setupGpioSubscriptions();
	$self->setupTemperatureSubscriptions();
	$self->setupTemperatureArchive();

	AnyEvent::Loop::run;
}

##
# Set up the listeners for switch subscribed topics
sub setupGpioSubscriptions {
	my ($self) = @ARG;
	$self->{MQTT}->subscribe(
		topic    => 'onoff/+/state',
		callback => sub {
			my ( $topic, $message ) = @ARG;
			$self->logOnOffState( $topic, $message );
		}
	);

	$self->{MQTT}->subscribe(
		topic    => 'switches/+/state',
		callback => sub {
			my ( $topic, $message ) = @ARG;
			$self->logSwitchState( $topic, $message );
		}
	);
}

##
# Set up the listeners for temperature subscribed topics
sub setupTemperatureSubscriptions {
	my ($self) = @ARG;
	$self->{MQTT}->subscribe(
		topic    => 'sensors/temperature/+/temperature',
		callback => sub {
			my ( $topic, $message ) = @ARG;
			$self->logTemperature( $topic, $message );
		}
	);
}

##
# Log a switch message to the database
# @param topic the MQTT topic
# @param message the MQTT message
sub logSwitchState {
	my ( $self, $topic, $message ) = @ARG;

	$topic =~ /switches\/(.+)\/state/
	  or return;
	my $device = $1;

	my $rec = $self->{DB}->resultset('SwitchLog')->new(
		{
			device => $1,
			time   => $self->getCurrentTimeDB() . '',    # Stringify here to force milliseconds
			value  => $message,
		}
	);
	$rec->insert();
}

##
# Log an on/off message to the database
# @param topic the MQTT topic
# @param message the MQTT message
sub logOnOffState {
	my ( $self, $topic, $message ) = @ARG;

	$topic =~ /onoff\/(.+)\/state/
	  or return;
	my $device = $1;

	my $rec = $self->{DB}->resultset('OnOffLog')->new(
		{
			device => $1,
			time   => $self->getCurrentTimeDB() . '',    # Stringify here to force milliseconds
			value  => $message,
		}
	);
	$rec->insert();
}

##
# Log a temperature message to the database
# @param topic the MQTT topic
# @param message the MQTT message
sub logTemperature {
	my ( $self, $topic, $message ) = @ARG;

	$topic =~ /sensors\/temperature\/(.+)\/temperature/
	  or return;
	my $device = $1;

	my $rec = $self->{DB}->resultset('TemperatureReading')->new(
		{
			device => $1,
			time   => $self->getCurrentTimeDB() . '',    # Stringify here to force milliseconds
			value  => $message,
		}
	);
	$rec->insert();
}

##
# Periodically update min/max/mean temperatures for today
sub setupTemperatureArchive {
	my ($self) = @ARG;

	$self->{TEMPERATURE_ARCHIVE_TIMER} = AnyEvent->timer(
		after    => 0,
		interval => 5 * 60,
		cb       => sub {
			$self->archiveDaysTemperatures( $self->getCurrentTimeDB() );

			my $time = DateTime->from_epoch(
				time_zone => $self->{TIMEZONE},
				epoch     => AnyEvent->now(),
			);
			my $midnight = $time->clone();
			$midnight->truncate( to => 'day' );

			if ( $time->add( minutes => 5 )->subtract_datetime($midnight)->is_negative() ) {    # Final processing for yesterday
				$self->archiveDaysTemperatures( $self->getCurrentTimeDB()->subtract( days => 1 ) );
			}
		}
	);
}

##
# Create a minimum/maximum temperature record for a day (all sensors)
# @param day the day to create the record for
sub archiveDaysTemperatures {
	my ( $self, $day ) = @ARG;

	my $dayStart = $day->clone();
	$dayStart->truncate( to => 'day' );

	my $dayEnd = $dayStart->clone();
	$dayEnd->add( days => 1 );

	# Find the devices
	my @devices = $self->{DB}->resultset('TemperatureReading')->search(
		{
			'time' => { '>=' => $dayStart . '', '<' => $dayEnd . '' },
		},
		{
			columns  => ['device'],
			distinct => 1
		}
	)->get_column('device')->all();

	foreach my $device (@devices) {
		$self->archiveDaysTemperaturesForDevice( $dayStart, $dayEnd, $device );
	}

}

##
# Create a minimum/maximum temperature record for a day
# @param dayStart the minimum time to create the record for
# @param dayEnd the maximum time to create the record for
# @param device the sensor to create the record for
sub archiveDaysTemperaturesForDevice {
	my ( $self, $dayStart, $dayEnd, $device ) = @ARG;

	my $rs = $self->{DB}->resultset('TemperatureReading')->search(
		{
			'time'   => { '>=' => $dayStart . '', '<' => $dayEnd . '' },
			'device' => $device,
		},
	);

	my $times    = $rs->get_column('value');
	my $maxTemp  = $times->max();
	my $minTemp  = $times->min();
	my $meanTemp = $times->sum() / $rs->count();

	my $day = $dayStart->strftime('%Y-%m-%d'); # Required as 'Y-m-d' != 'Y-m-d 00:00:00'

	my $rec = $self->{DB}->resultset('DailyTemperature')->update_or_create(
		{
			device => $device,
			date   => $day,
			mean   => $meanTemp,
			min    => $minTemp,
			max    => $maxTemp,
		}
	);
	$rec->insert();
}

1;

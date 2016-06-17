package Daemon::Logger;

use strict;
use warnings;
use English;

use AnyEvent;
use AnyEvent::MQTT;
use DateTime;
use DateTime::Format::Strptime;
use Time::HiRes qw(time);

##
# Create a new logger daemon
# @param class the class of this object
# @param db the database instance
# @param mqtt the MQTT instance
sub new {
	my ( $class, $db, $generalConfig, $mqtt ) = @ARG;

	my $self = {};
	bless $self, $class;

	$self->{MQTT} = $mqtt;
	$self->{DB}   = $db;

	$self->{TIMEZONE} = $generalConfig->{timezone};

	$self->setupGpioSubscriptions();
	$self->setupTemperatureSubscriptions();
	$self->setupTemperatureArchive();

	return $self;
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
# Get the current time in a db suitable format
sub getCurrentTime {
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
			time   => $self->getCurrentTime() . '',    # Stringify here to force milliseconds
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
			time   => $self->getCurrentTime() . '',    # Stringify here to force milliseconds
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
			time   => $self->getCurrentTime() . '',    # Stringify here to force milliseconds
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
			$self->archiveDaysTemperatures( $self->getCurrentTime() );

			my $time = DateTime->from_epoch(
				time_zone => $self->{TIMEZONE},
				epoch     => AnyEvent->now(),
			);
			my $midnight = $time->clone();
			$midnight->truncate( to => 'day' );

			if ( $time->add( minutes => 5 )->subtract_datetime($midnight)->is_negative() ) {    # Final processing for yesterday
				$self->archiveDaysTemperatures( $self->getCurrentTime()->subtract( days => 1 ) );
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

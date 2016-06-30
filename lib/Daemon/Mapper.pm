package Daemon::Mapper;

use strict;
use warnings;
use English;

use AnyEvent;
use AnyEvent::MQTT;
use AnyEvent::Loop;

use JSON::Parse;

use aliased 'DBIx::Class::DeploymentHandler' => 'DH';
use DB::Schema;

use base 'Daemon';

##
# Create a new mapper daemon
# @param class the class of this object
# @param generalConfig the general configuration
# @param dbConfig the database config
# @param mqttConfig the MQTT config (hashref)
sub new {
	my ( $class, $generalConfig, $dbConfig, $mqttConfig ) = @ARG;

	my $self = $class->SUPER::new($generalConfig);
	bless $self, $class;

	$self->{DEBUG} = 1;

	$self->{MQTT_CONFIG}    = $mqttConfig;
	$self->{DBCONFIG}       = $dbConfig;
	$self->{MAPPING_COUNTS} = {};
	$self->{MAPPINGS}       = {};

	return $self;
}

##
# Connect to the database
sub connectDatabase {
	my ($self) = @ARG;

	$self->{DB} = DB::Schema->connect(
		$self->{DBCONFIG}->{dsn},
		$self->{DBCONFIG}->{user},
		$self->{DBCONFIG}->{password}
	);
}

##
# Run the Mapper daemon in a new process
sub run {
	my ($self) = @ARG;

	my $pid = fork();
	if ($pid) {
		return $pid;
	}

	$self->connectDatabase( $self->{DBCONFIG} );

	$self->{MQTT_CONFIG}->{client_id} = 'HomeAutomation mapping daemon';

	$self->{MQTT} = new AnyEvent::MQTT( %{ $self->{MQTT_CONFIG} } );

	$self->loadMappingsFromDB();

	$self->setupMappingSubscriptions();

	AnyEvent::Loop::run;
}

##
# Set up the listeners for switch subscribed topics
sub setupMappingSubscriptions {
	my ($self) = @ARG;
	$self->{MQTT}->subscribe(
		topic    => 'mapper/addmapping',
		callback => sub {
			my ( $topic, $message ) = @ARG;
			$self->addMapping($message);
		}
	);
	$self->debug("Subscribed to 'mapper/addmapping'");

	$self->{MQTT}->subscribe(
		topic    => 'mapper/deletemapping',
		callback => sub {
			my ( $topic, $message ) = @ARG;
			$self->deleteMapping($message);
		}
	);
	$self->debug("Subscribed to 'mapper/deletemapping'");
}

##
# Unregister a mapping
# @param from the topic to map from
# @param to the topic to map to
sub unregisterMapping {
	my ( $self, $from, $to ) = @ARG;

	delete $self->{MAPPINGS}->{$from}->{$to};

	$self->debug("Unregistered mapping '$from' -> '$to'");


# Unsubscribing will remove all callbacks, so we only unsubscribe when
# there are no more callbacks left (early exit in the callback to deactivate the dangling ones)
	my $count = keys %{ $self->{MAPPINGS}->{$from} };
	if ( 0 == $count ) {
		$self->debug("No more callbacks left, removing subscription for '$from'");
		my $cv = $self->{MQTT}->unsubscribe( topic => $from );
	}
}

##
# Register a mapping
# @param from the topic to map from
# @param to the topic to map to
# @param transform a transformation to apply
sub registerMapping {
	my ( $self, $from, $to, $transform ) = @ARG;

	$transform //= 'return $ARG;';

	$self->debug("Registered mapping '$from' -> '$to' with transform '$transform'");

	$self->{MAPPINGS}->{$from} //= {};
	$self->{MAPPINGS}->{$from}->{$to} = sub { my ($ARG) = @ARG; eval($transform); };

	$self->{MQTT}->subscribe(
		topic    => $from,
		callback => sub {
			my ( $topic, $message ) = @ARG;

			$self->debug("Mapping '$from' -> '$to'");

			my $xform = $self->{MAPPINGS}->{$from}->{$to};
			if ( !defined $xform ) {
				return
				  ; # Early exit for deleted mappings that we are still subscribed to
			}

			my $out = &$xform($message);

			$self->debug("Transformed '$message' to '$out'");

			my $cv = $self->{MQTT}->publish(
				topic   => $to,
				message => $out,
				retain  => 1,
			);
			push @{ $self->{CVS} }, $cv;
		}
	);
}

##
# Load mappings from the database
sub loadMappingsFromDB {
	my ($self) = @ARG;

	my @mappings = $self->{DB}->resultset('Mapping')->search({})->all();

	foreach my $mapping (@mappings) {
		$self->registerMapping($mapping->source(), $mapping->destination(), $mapping->transform());
	}
}

##
# Add a mapping from one topic to another
# @param message a json hash mapping the keys 'from', 'to' and 'transform'
# from and to are MQTT topics, transform is a perl snippet that operates on $ARG (the from value) and returns the to value
sub addMapping {
	my ( $self, $message ) = @ARG;

	my $parms = JSON::Parse::parse_json($message);

	$self->debug("Adding mapping '$parms->{from}' -> '$parms->{to}' with transform '$parms->{transform}'");

	my $rec = $self->{DB}->resultset('Mapping')->update_or_create(
		{
			source      => $parms->{from},
			destination => $parms->{to},
			transform   => $parms->{transform},
		}
	);
	$rec->insert();

	$self->unregisterMapping( $parms->{from}, $parms->{to} );
	$self->registerMapping( $parms->{from}, $parms->{to}, $parms->{transform} );
}

##
# Delete a mapping from one topic to another
# @param message a json hash mapping the keys 'from', 'to'
# from and to are MQTT topics, transform is a perl snippet that operates on $ARG (the from value) and returns the to value
sub deleteMapping {
	my ( $self, $message ) = @ARG;

	my $parms = JSON::Parse::parse_json($message);

	$self->debug("Deleting mapping '$parms->{form}' -> '$parms->{to}'");

	my $rec = $self->{DB}->resultset('Mapping')->find(
		{
			source      => $parms->{from},
			destination => $parms->{to},
		}
	);
	$rec->delete();

	$self->unregisterMapping( $parms->{from}, $parms->{to} );
}

1;

#!/usr/bin/perl

use strict;
use warnings;
use English;
use TOML;
use File::Slurp;
use Getopt::Long;
use Sys::Syslog qw(:standard :macros);

use lib 'lib';

use AnyEvent;
use AnyEvent::Loop;
use AnyEvent::MQTT;

use aliased 'DBIx::Class::DeploymentHandler' => 'DH';
use DB::Schema;

use Daemon::OneWire;
use Daemon::Logger;

my $config;

my $install;
my $upgrade;

##
# Read in the config file
# @param file the path to the file
sub readConfig {
	my ($file) = @ARG;

	my $fileContents = read_file($file) or die "Could not read config file '$file': $OS_ERROR";

	my $err;
	( $config, $err ) = TOML::from_toml($fileContents);
	die "Could not parse config: $err" unless defined $config;
}

##
# Find and load the config file
sub loadConfig {
	my $file = $ENV{HA_CONFIG} // 'ha.toml';

	-f $file or $file = '/usr/local/etc/ha.toml';
	-f $file or $file = '/etc/ha.toml';
	-f $file or die "Could not find config file";

	readConfig($file);
}

##
# Connect to the database
sub connectDatabase {
	my ($dbConfig) = @ARG;

	my $db = DB::Schema->connect( $dbConfig->{dsn}, $dbConfig->{user}, $dbConfig->{password} );

	return $db;
}

##
# Install the database schema
sub installDatabase {
	my ( $db, $dbConfig ) = @ARG;

	$dbConfig->{dsn} =~ /:(.+):/
	  or die "Could not extract DB type from DSN '$dbConfig->{dsn}'";
	my $dbType = $1;

	my $dh = DH->new(
		{
			schema              => $db,
			databases           => $dbType,
			sql_translator_args => { add_drop_table => 0, force_overwrite => 1 },
		}
	);

	$dh->prepare_install;
	$dh->install;
}

GetOptions(
	"install" => \$install,
	"upgrade" => \$upgrade
) or die("Error in command line arguments\n");

openlog( 'ndelay,pid', LOG_DAEMON );

syslog( LOG_DEBUG, 'loading config' );
loadConfig();

my %threads;

my $oneWireConfig = $config->{'1wire'};
my $dbConfig      = $config->{'database'};
our $generalConfig = $config->{'general'};

my %mqttConfig = %{ $config->{'mqtt'} };
$mqttConfig{on_error} = sub { my ( $fatal, $message ) = @ARG; warn $message; };
$mqttConfig{client_id} = 'HomeAutomation Central';

my $mqtt = new AnyEvent::MQTT(%mqttConfig);
my $db   = connectDatabase($dbConfig);

if ($install) {
	installDatabase( $db, $dbConfig )
	  or die "DB creation failed";
}

my $logger = new Daemon::Logger( $db, $generalConfig, $mqtt );

if ( defined $oneWireConfig ) {
	my $oneWire = new Daemon::OneWire( $oneWireConfig, $mqtt );
}

AnyEvent::Loop::run;

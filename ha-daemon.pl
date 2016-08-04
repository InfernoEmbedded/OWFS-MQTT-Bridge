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

use Daemon::OneWire;
use Daemon::WeMo;
use Daemon::Scene;
use Daemon::Shutter;
use Daemon::Logger;
use Daemon::Mapper;
use Daemon::Scheduler;
use Daemon::WebServer;

my $config;

my $install;
my $upgrade;

my @children; # Child processes
my @daemons; # Daemons to propagate signals to

$SIG{KILL} = sub {
	foreach my $daemon (@daemons) {
		$daemon->kill();
	}

	exit 1;
};

$SIG{TERM} = sub {
	foreach my $daemon (@daemons) {
		$daemon->kill();
	}

	exit 1;
};

$SIG{INT} = sub {
	foreach my $daemon (@daemons) {
		$daemon->kill();
	}

	exit 1;
};


##
# Read in the config file
# @param file the path to the file
sub readConfig {
	my ($file) = @ARG;

	my $fileContents = read_file($file)
	  or die "Could not read config file '$file': $OS_ERROR";

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

GetOptions(
	"install" => \$install,
	"upgrade" => \$upgrade
) or die("Error in command line arguments\n");

openlog( 'ndelay,pid', LOG_DAEMON );

syslog( LOG_DEBUG, 'loading config' );
loadConfig();

my $oneWireConfig = $config->{'1wire'};
my $wemoConfig    = $config->{'wemo'};
my $httpConfig    = $config->{'http'};
my $dbConfig      = $config->{'database'};
our $generalConfig = $config->{'general'};

my %mqttConfig = %{ $config->{'mqtt'} };
$mqttConfig{on_error} = sub {
	my ( $fatal, $message ) = @ARG;
	warn("MQTT error on $mqttConfig{host}:$mqttConfig{port}: $message");
};
$mqttConfig{client_id} = 'HomeAutomation Central';

my $logger = new Daemon::Logger( $generalConfig, $dbConfig, \%mqttConfig );
if ($install) {
	$logger->installDatabase($dbConfig)
	  or die "DB creation failed";
}
push @children, $logger->run();
push @daemons, $logger;

my $mapper = new Daemon::Mapper( $generalConfig, $dbConfig, \%mqttConfig );
push @children, $mapper->run();
push @daemons, $mapper;

if ( defined $wemoConfig ) {
	my $wemo = new Daemon::WeMo( $generalConfig, $wemoConfig, \%mqttConfig );
	push @children, $wemo->run();
	push @daemons, $wemo;
}

my $mqtt = new AnyEvent::MQTT(%mqttConfig);

if ( defined $oneWireConfig ) {
	my $oneWire = new Daemon::OneWire( $generalConfig, $oneWireConfig, $mqtt );
	push @daemons, $oneWire;
}

my $scene = new Daemon::Scene( $generalConfig, $mqtt );
push @daemons, $scene;

my $shutter = new Daemon::Shutter( $generalConfig, $mqtt );
push @daemons, $shutter;

my $scheduler = new Daemon::Scheduler( $generalConfig, $mqtt );
push @daemons, $scheduler;

my $webServer = new Daemon::WebServer( $generalConfig, $httpConfig, \%mqttConfig );
push @daemons, $webServer;

AnyEvent::Loop::run;


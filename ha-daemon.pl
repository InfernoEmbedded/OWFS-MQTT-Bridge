#!/usr/bin/perl

use strict;
use warnings;
use English;
use TOML;
use File::Slurp;
use Sys::Syslog qw(:standard :macros);
use Net::MQTT::Simple;
use threads;
use threads::shared;

use Daemon::OneWire;


my $config;

##
# Read in the config file
# @param file the path to the file
sub readConfig {
	my ($file) = @ARG;

	my $fileContents = read_file($file) or die "Could not read config file '$file': $OS_ERROR";

	my $err;
	($config, $err) = TOML::from_toml($fileContents);
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

openlog('ndelay,pid', LOG_DAEMON);

syslog(LOG_DEBUG, 'loading config');
loadConfig();

my %threads;

my $oneWireConfig = $config->{'1wire'};
my $mqttConfig = $config->{'mqtt'};

if (defined $oneWireConfig) {
	my $oneWire = new Daemon::OneWire($oneWireConfig, $mqttConfig);
	%threads = (%threads, $oneWire->run());
}

foreach my $thread (keys %threads) {
	$threads{$thread}->join();
}
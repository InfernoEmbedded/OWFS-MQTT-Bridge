package Daemon::WebServer;

use strict;
use warnings;
use English;

use AnyEvent;
use AnyEvent::MQTT;
use AnyEvent::HTTPD;
use AnyEvent::AIO;
use IO::AIO;

use HTML::Template::Pro;
use MIME::Types;
use File::Basename;
use Fcntl;

use Data::Dumper;
use Carp;

use base 'Daemon';

##
# Create a new HTTP daemon
# @param class the class of this object
# @param generalConfig the general configuration
# @param httpConfig the HTTP configuration
# @param mqttConfig the MQTT configuration
sub new {
	my ( $class, $generalConfig, $httpConfig, $mqttConfig ) = @ARG;

	my $self = $class->SUPER::new($generalConfig);
	bless $self, $class;

	$self->{DEBUG}       = 1;
	$self->{HTTP_CONFIG} = $httpConfig;
	$self->{MQTT_CONFIG} = $mqttConfig;

	$self->{HTTPD}     = new AnyEvent::HTTPD( %{$httpConfig} );
	$self->{TEMPLATES} = {};
	$self->{MIME}      = new MIME::Types();

	$self->registerPaths();

	return $self;
}

##
# Register the HTTP paths against their handlers
sub registerPaths {
	my ($self) = @ARG;

	$self->{HTTPD}->reg_cb(
		'/configure' =>
		  sub { $self->showConfigure(@ARG); $ARG[0]->stop_request(); },
		'/' => sub { $self->showRoot(@ARG);    $ARG[0]->stop_request(); },
		''  => sub { $self->deliverFile(@ARG); $ARG[0]->stop_request(); }
	);
}

##
# Deliver a file to the web client
# @param httpd the server instance
# @param req the HTTP request object
sub deliverFile {
	my ( $self, $httpd, $req ) = @ARG;

	my $file = 'webroot' . $req->url();

	-f $file or do {
		$self->logError("404 '$file' not found");
		$req->respond(
			[
				404, 'not found', { 'Content-Type' => 'text/plain' },
				'not found'
			]
		);
		return;
	};

	my $mimetype = $self->{MIME}->mimeTypeOf($file)->type();
	$self->debug( "Request for URL '"
		  . $req->url()
		  . "', will deliver '$file' of type '$mimetype'" );

	# use IO::AIO to async open the file
	aio_open $file, O_RDONLY, 0, sub {
		my ($fh) = @ARG;

		unless ($fh) {
			$self->logError("couldn't open $file: $OS_ERROR");
			$req->respond(
				[
					404, 'not found', { 'Content-Type' => 'text/plain' },
					'not found'
				]
			);
			return;
		}

		my $size = -s $fh;

		$self->debug("opened $file, $size bytes");
#		my $offset = 0;

		# make a reader callback, that will be called
		# whenever a chunk of data was written out to the kernel
		my $getChunk = sub {
			my ($dataCallback) = @ARG;

			return unless $dataCallback;

			my $chunk = '';

			aio_read $fh, undef, 16384, $chunk, 0, sub {
				my ($length) = @ARG;

				if ( $length > 0 ) {
					$dataCallback->($chunk);
#					$offset += $length;

					return;
					# and here we just return, and wait for the next call to
					# $getChunk when the data is in the kernel.

				} else {
					$dataCallback->()
					  ;    # stop sending data (in case of error or EOF)
					return;
				}
			};
		};    # End of getChunk

		$req->respond(
			[
				200, 'OK',
				{
					'Content-Type'  => $mimetype,
					'Cache-Control' => 'max-age=3600',
					'Expires'       => undef,
					'Content-Length' => $size,
				},
				$getChunk
			]
		);
	};
}

##
# Show the configure page
# @param httpd the server instance
# @param req the HTTP request object
sub showRoot {
	my ( $self, $httpd, $req ) = @ARG;

	$self->{TEMPLATES}->{'root.html'} //=
	  HTML::Template::Pro->new( filename => 'templates/root.html' );

	my $template = $self->{TEMPLATES}->{'root.html'};

	$template->param( HOME => $ENV{HOME} );
	$template->param( PATH => $ENV{PATH} );

	$req->respond(
		[
			200, 'OK',
			{
				'Content-Type' => 'text/html',
			},
			$template->output(),
		]
	);
}

##
# Show the configure page
# @param httpd the server instance
# @param req the HTTP request object
sub showConfigure {
	my ( $self, $httpd, $req ) = @ARG;

	$self->{TEMPLATES}->{'configure.html'} //=
	  HTML::Template::Pro->new( filename => 'templates/configure.html' );

	my $template = $self->{TEMPLATES}->{'configure.html'};

	$template->param( mqttWebSocketHost => $self->{MQTT_CONFIG}->{websocket_host} );
	$template->param( mqttWebSocketPort => $self->{MQTT_CONFIG}->{websocket_port} );

	$req->respond(
		[
			200, 'OK',
			{
				'Content-Type' => 'text/html',
			},
			$template->output(),
		]
	);
}

1;

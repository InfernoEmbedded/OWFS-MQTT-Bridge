package DB::Schema::Result::TemperatureReading;

use strict;
use warnings;

use base 'DBIx::Class::Core';

__PACKAGE__->load_components(qw/InflateColumn::DateTime/);

__PACKAGE__->table('temperature_log');

__PACKAGE__->add_columns(
	'device' => {
		data_type => 'varchar',
		size      => '255',
	},
	'time' => {
		data_type     => 'datetime',
		timezone  => $main::generalConfig->{timezone},
	},
	'value' => {
		data_type => 'float',
	},
);

__PACKAGE__->set_primary_key('device', 'time');

1;

package DB::Schema::Result::DailyTemperature;

use strict;
use warnings;

use base 'DBIx::Class::Core';

__PACKAGE__->load_components(qw/InflateColumn::DateTime/);

__PACKAGE__->table('daily_temperature');

__PACKAGE__->add_columns(
	'device' => {
		data_type => 'varchar',
		size      => '255',
	},
	'date' => {
		data_type     => 'date',
	},
	'mean' => {
		data_type => 'float',
	},
	'min' => {
		data_type => 'float',
	},
	'max' => {
		data_type => 'float',
	},
);

__PACKAGE__->set_primary_key('device', 'date');

1;

package DB::Schema::Result::Mapping;

use strict;
use warnings;

use base 'DBIx::Class::Core';

__PACKAGE__->table('mapping');

__PACKAGE__->add_columns(
	'source' => {
		data_type => 'varchar',
		size      => '255',
	},
	'destination' => {
		data_type => 'varchar',
		size      => '255',
	},
	'transform' => {
		data_type => 'varchar',
		size      => '255',
	},
);

__PACKAGE__->set_primary_key('source', 'destination');

1;

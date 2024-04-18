use utf8;
package Bio::KBase::AppService::Schema::Result::AllTask;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Bio::KBase::AppService::Schema::Result::AllTask - VIEW

=cut

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 COMPONENTS LOADED

=over 4

=item * L<DBIx::Class::InflateColumn::DateTime>

=back

=cut

__PACKAGE__->load_components("InflateColumn::DateTime");
__PACKAGE__->table_class("DBIx::Class::ResultSource::View");

=head1 TABLE: C<AllTasks>

=cut

__PACKAGE__->table("AllTasks");

=head1 ACCESSORS

=head2 id

  data_type: 'integer'
  is_nullable: 0

=head2 submit_time

  data_type: 'timestamp'
  datetime_undef_if_invalid: 1
  default_value: '1970-01-01 00:00:00'
  is_nullable: 0

=head2 application_id

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=head2 owner

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=head2 state_code

  data_type: 'varchar'
  is_nullable: 1
  size: 10

=head2 base_url

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=cut

__PACKAGE__->add_columns(
  "id",
  { data_type => "integer", is_nullable => 0 },
  "submit_time",
  {
    data_type => "timestamp",
    datetime_undef_if_invalid => 1,
    default_value => "1970-01-01 00:00:00",
    is_nullable => 0,
  },
  "application_id",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "owner",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "state_code",
  { data_type => "varchar", is_nullable => 1, size => 10 },
  "base_url",
  { data_type => "varchar", is_nullable => 1, size => 255 },
);


# Created by DBIx::Class::Schema::Loader v0.07052 @ 2024-04-18 10:56:27
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:g4LBKlXfl139CI097PWuNQ


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;

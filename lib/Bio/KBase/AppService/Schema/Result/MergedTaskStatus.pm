use utf8;
package Bio::KBase::AppService::Schema::Result::MergedTaskStatus;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Bio::KBase::AppService::Schema::Result::MergedTaskStatus - VIEW

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

=head1 TABLE: C<MergedTaskStatus>

=cut

__PACKAGE__->table("MergedTaskStatus");

=head1 ACCESSORS

=head2 id

  data_type: 'integer'
  default_value: 0
  is_nullable: 0

=head2 owner

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=head2 state_code

  data_type: 'varchar'
  is_nullable: 1
  size: 10

=head2 job_status

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=cut

__PACKAGE__->add_columns(
  "id",
  { data_type => "integer", default_value => 0, is_nullable => 0 },
  "owner",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "state_code",
  { data_type => "varchar", is_nullable => 1, size => 10 },
  "job_status",
  { data_type => "varchar", is_nullable => 1, size => 255 },
);


# Created by DBIx::Class::Schema::Loader v0.07052 @ 2024-04-18 10:56:27
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:ThhihOsi5WsrNLtHOb/e0A


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;

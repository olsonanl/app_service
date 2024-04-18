use utf8;
package Bio::KBase::AppService::Schema::Result::BySiteStatsGatherNonCollab;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Bio::KBase::AppService::Schema::Result::BySiteStatsGatherNonCollab - VIEW

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

=head1 TABLE: C<BySiteStatsGatherNonCollab>

=cut

__PACKAGE__->table("BySiteStatsGatherNonCollab");

=head1 ACCESSORS

=head2 month

  data_type: 'integer'
  is_nullable: 1

=head2 year

  data_type: 'integer'
  extra: {unsigned => 1}
  is_nullable: 1

=head2 application_id

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=head2 site

  data_type: 'varchar'
  default_value: (empty string)
  is_nullable: 0
  size: 6

=head2 job_count

  data_type: 'bigint'
  default_value: 0
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "month",
  { data_type => "integer", is_nullable => 1 },
  "year",
  { data_type => "integer", extra => { unsigned => 1 }, is_nullable => 1 },
  "application_id",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "site",
  { data_type => "varchar", default_value => "", is_nullable => 0, size => 6 },
  "job_count",
  { data_type => "bigint", default_value => 0, is_nullable => 0 },
);


# Created by DBIx::Class::Schema::Loader v0.07052 @ 2024-04-18 10:56:27
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:OEHS8bAFvllOYYMg322mDw


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;

use utf8;
package Bio::KBase::AppService::Schema::Result::ApplicationSpec;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Bio::KBase::AppService::Schema::Result::ApplicationSpec

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

=head1 TABLE: C<ApplicationSpec>

=cut

__PACKAGE__->table("ApplicationSpec");

=head1 ACCESSORS

=head2 id

  data_type: 'varchar'
  is_nullable: 0
  size: 64

=head2 application_id

  data_type: 'varchar'
  is_foreign_key: 1
  is_nullable: 1
  size: 255

=head2 spec

  data_type: 'json'
  is_nullable: 1

=head2 first_seen

  data_type: 'timestamp'
  datetime_undef_if_invalid: 1
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "id",
  { data_type => "varchar", is_nullable => 0, size => 64 },
  "application_id",
  { data_type => "varchar", is_foreign_key => 1, is_nullable => 1, size => 255 },
  "spec",
  { data_type => "json", is_nullable => 1 },
  "first_seen",
  {
    data_type => "timestamp",
    datetime_undef_if_invalid => 1,
    is_nullable => 1,
  },
);

=head1 PRIMARY KEY

=over 4

=item * L</id>

=back

=cut

__PACKAGE__->set_primary_key("id");

=head1 RELATIONS

=head2 application

Type: belongs_to

Related object: L<Bio::KBase::AppService::Schema::Result::Application>

=cut

__PACKAGE__->belongs_to(
  "application",
  "Bio::KBase::AppService::Schema::Result::Application",
  { id => "application_id" },
  {
    is_deferrable => 1,
    join_type     => "LEFT",
    on_delete     => "RESTRICT",
    on_update     => "RESTRICT",
  },
);


# Created by DBIx::Class::Schema::Loader v0.07052 @ 2024-04-18 10:56:27
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:hz44PaBjkWpWQiewWW9/uQ


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;

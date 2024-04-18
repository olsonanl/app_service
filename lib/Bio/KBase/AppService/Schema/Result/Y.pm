use utf8;
package Bio::KBase::AppService::Schema::Result::Y;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Bio::KBase::AppService::Schema::Result::Y

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

=head1 TABLE: C<y>

=cut

__PACKAGE__->table("y");

=head1 ACCESSORS

=head2 id

  data_type: 'integer'
  is_nullable: 1

=cut

__PACKAGE__->add_columns("id", { data_type => "integer", is_nullable => 1 });


# Created by DBIx::Class::Schema::Loader v0.07052 @ 2024-04-18 10:56:28
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:M2qgdK9Dif/ug4sxZEyr1w


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;

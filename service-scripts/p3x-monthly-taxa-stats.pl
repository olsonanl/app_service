use Data::Dumper;
use strict;
use P3DataAPI;

my @taxa = qw(
469
    1386
    773
    64895
    234
    32008
    194
    810
    1485
    776
    943
    561
    262
    209
    1637
    1763
    286
    780
    590
    620
    1279
    1301
    662
    629
	     );

my $api = P3DataAPI->new;

print join("\t", "Taxa", "Taxon ID", "Domain", "Species", "Genomes"), "\n";

for my $id (@taxa)
{
    my @res = $api->query("taxonomy", ["eq", "taxon_id", $id], ["select", "division,taxon_name"]);
    my $domain = $res[0]->{division};
    my $name = $res[0]->{taxon_name};

    my @res = $api->query("genome",
			  ["eq", "public", 1],
			  ["eq", "taxon_lineage_ids", $id],
			  ["select", "genome_id,genus,species"]);
    my $n = @res;
    my %species;
    $species{$_->{species}}++ foreach @res;

    my $ns = keys %species;
    print join("\t", $name, $id, $domain, $ns, $n), "\n";
}
				


#
# Resubmit a job's load files for indexing.
#

use strict;
use P3AuthToken;
use File::Temp;
use File::Basename;
use Bio::KBase::AppService::SchedulerDB;
use Bio::P3::Workspace::WorkspaceClientExt;
use Bio::KBase::AppService::AppConfig qw(data_api_url);
use Getopt::Long::Descriptive;
use Data::Dumper;
use JSON::XS;
use IPC::Run;

my($opt, $usage) = describe_options("%c %o jobid...",
				    ["help|h" => "Show this help message"]);

print($usage->text), exit 0 if $opt->help;
print($usage->text), exit 1 if @ARGV == 0;

my @jobs = @ARGV;

my $db = Bio::KBase::AppService::SchedulerDB->new;
my $ws = Bio::P3::Workspace::WorkspaceClientExt->new;
my $token = P3AuthToken->new;

my @conds;
my @params;

for my $id (@jobs)
{
    if ($id !~ /^\d+$/)
    {
	die "Invalid job id $id\n";
    }
}
my $vals = join(", ", @jobs);

push(@conds, "id IN ($vals)");

my $cond = join(" AND ", map { "($_)" } @conds);

my $qry = qq(SELECT id, output_path, output_file, application_id
	     FROM Task
	     WHERE $cond);


my $res = $db->dbh->selectall_arrayref($qry, undef, @params);

for my $ent (@$res)
{
    my($job_id, $output_path, $output_file, $app_id) = @$ent;

    if ($app_id eq 'ComprehensiveGenomeAnalysis')
    {
	$output_path .= "/.$output_file";
	$output_file = "annotation";
    }

    resubmit_load_files($job_id, $output_path, $output_file, $app_id);
}

sub resubmit_load_files
{
    my($job_id, $output_path, $output_file, $app_id) = @_;

    my $temp = File::Temp->newdir(CLEANUP => 1);
    my $genome_url = data_api_url . "/indexer/genome";

    my $path = "$output_path/.$output_file/load_files";
    print "$path\n";
    my $res = $ws->ls({ paths => [$path], adminmode => 1 });
    my @opts;
    push(@opts, "-H", "Authorization: " . $token->token);
    push(@opts, "-H", "Content-Type: multipart/form-data");
    
    for my $ent (@{$res->{$path}})
    {
	my($file, $type, $path) = @$ent;
	next unless $type eq 'json';
	my $dest = "$temp/$file";

	my $key = basename($file, ".json");

	my $x = $ws->download_file("$path$file", $dest, 1, $token->token, { admin => 1 });

	push(@opts, "-F", "$key=\@$dest");
    }
    push(@opts, $genome_url);
    die Dumper(@opts);

#curl -H "Authorization: AUTHORIZATION_TOKEN_HERE" -H "Content-Type: multipart/form-data" -F "genome=@genome.json" -F "genome_feature=@genome_feature_patric.json" -F "genome_feature=@genome_feature_refseq.json" -F "genome_feature=@genome_feature_brc1.json" -F "genome_sequence=@genome_sequence.json" -F "pathway=@pathway.json" -F "sp_gene=@sp_gene.json"  

    my($stdout, $stderr);
    
    my $ok = IPC::Run::run(["curl", @opts], '>', \$stdout);
    if (!$ok)
    {
	warn "Error $? invoking curl @opts\n";
    }

    my $json = JSON::XS->new->allow_nonref;
    my $data = $json->decode($stdout);

    my $queue_id = $data->{id};

    print "Submitted indexing job $queue_id\n";
}

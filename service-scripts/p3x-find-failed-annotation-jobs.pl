

#
# For a given date range, search for the annotation jobs
# that had a failure on the invocation of the kmer annotation service.
#


use strict;
use Bio::KBase::AppService::SchedulerDB;
use Getopt::Long::Descriptive;
use Data::Dumper;

my $db = Bio::KBase::AppService::SchedulerDB->new;
my $dbh = $db->dbh;


my($opt, $usage) = describe_options("%c %o start end",
				    ["help|h" => "Show this help message"]);
print($usage->text), exit 0 if $opt->help;
die($usage->text) if @ARGV != 2;

my $start_time = shift;
my $end_time = shift;

my $qry = q(SELECT id, owner, start_time, finish_time, state_code, application_id
	     FROM Task
	     WHERE finish_time >= ? AND
	     start_time <= ? AND
	     owner = 'BVBRC@patricbrc.org' AND
	     application_id IN ('GenomeAnnotation', 'ComprehensiveGenomeAnalysis', 'GenomeAnnotationGenbank')
	    );
my $res = $dbh->selectall_hashref($qry, 'id', undef, $start_time, $end_time);
for my $ent (values %$res)
{
    my $dir = "/disks/p3/task_status/$ent->{id}";
    if (open(ERR, "<", "$dir/stderr"))
    {
	while (<ERR>)
	{
	    if (/cmd failed.*curl.*Kmer-Options/)
	    {
		my $err;
		while (<ERR>)
		{
		    if (/^curl/)
		    {
			chomp;
			$err = $_;
			last;
		    }
		    elsif (/^Finished/)
		    {
			last;
		    }
		}
		# Find the genome id
		if (open(OUT, "<", "$dir/stdout"))
		{
		    while (<OUT>)
		    {
			if (/^1\s+'(\d+\.\d+)'/)
			{
			    $ent->{genome_id} = $1;
			}
		    }
		    close(OUT);
		}
		else
		{
		    warn "Cannot open $dir/stdout: $!";
		}
		print join("\t", @$ent{qw(id owner genome_id application_id state_code start_time finish_time)}, $err), "\n";
	    }
	}
	close(ERR);
    }
    else
    {
	warn "Cannot open $dir/stderr: $!";
    }
	    
       
}
    

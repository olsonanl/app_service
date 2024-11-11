=head1 NAME
    
    p3x-archive-tasks - Archive task records in scheduler database
    
=head1 SYNOPSIS

    p3x-archive-tasks end-date
    
=head1 DESCRIPTION

Archive records from the Task table in the scheduler database into the ArchivedTask
table. In the process we denormalize the data in the TaskExecution and ClusterJob tables.

Only archive records submitted before end-date.    

We optionally delete the records as they are (successfully) archived.

=cut


use strict;
use Getopt::Long::Descriptive;
use Data::Dumper;
use Bio::KBase::AppService::SchedulerDB;
use DateTime::Format::MySQL;
use Digest::SHA qw(sha256_hex);
use JSON::XS;

my $json = JSON::XS->new->pretty(1)->relaxed(1);

my($opt, $usage) = describe_options("%c %o end-date",
				    ["max-records=i" => "Archive at most this many records"],
				    ["batch-size=i" => "Pull records in batches of this size", { default => 1 }],
				    ["first-record=i" => "Start archiving here and ignore state of archive table"],
				    ["test" => "Use the test database"],
				    ["delete" => "Delete archived records"],
				    ["help|h" => "Show this help message."],
				    );

print($usage->text), exit 0 if $opt->help;
die($usage->text) if @ARGV != 1;

my $end_date = shift;

my $end_dt = DateTime::Format::MySQL->parse_datetime($end_date);

print "Archive until $end_dt\n";

#
# Define the list of fields from Task. Note that we will be
# postprocessing the app_spec into a app_spec_id to normalize
# that data as it is rarely used but we do not wish to discard it.
#

my $task_schema = qq(
		             id INTEGER AUTO_INCREMENT PRIMARY KEY,
		             owner VARCHAR(255),
		             parent_task INTEGER,
		             state_code VARCHAR(10),
		             application_id VARCHAR(255),
		             submit_time TIMESTAMP DEFAULT '1970-01-01 00:00:00',
		             start_time TIMESTAMP DEFAULT '1970-01-01 00:00:00',
		             finish_time TIMESTAMP DEFAULT '1970-01-01 00:00:00',
		             monitor_url VARCHAR(255),
		             output_path TEXT,
		             output_file TEXT,
		             params TEXT,
		             app_spec TEXT,
		             req_memory VARCHAR(255),
		             req_cpu INTEGER,
		             req_runtime INTEGER,
		             req_policy_data TEXT,
		             req_is_control_task BOOLEAN,
		             search_terms text,
		             hidden BOOLEAN default FALSE,
		             container_id VARCHAR(255),
		             data_container_id VARCHAR(255),
		             base_url VARCHAR(255),
		             user_metadata TEXT,
);
my @task_fields = grep { defined($_) }  map { /^\s*(\S+)/; $1 } split(/\n/, $task_schema);

my @archive_task_fields = map { $_ eq "app_spec" ? "app_spec_id" : $_ } @task_fields;
push(@archive_task_fields, 'retry_index');

my $task_fields = join(", ", @task_fields);
my $archive_task_fields = join(", ", @archive_task_fields);
my $archive_task_qs = join(", ", map { "?" } @archive_task_fields);
    

my $sched_db = Bio::KBase::AppService::SchedulerDB->new();

if ($opt->test)
{
    my $dbh =  $sched_db->{dbh} = DBI->connect("dbi:mysql:AppTest;host=cedar.mcs.anl.gov", "olson", undef,
					   { AutoCommit => 1, RaiseError => 1 });
    $dbh or die "Cannot connect to database: " . $DBI::errstr;
    $dbh->do(qq(SET time_zone = "+00:00"));
}

my $dbh = $sched_db->dbh();

$dbh->{RaiseError} = 1;

#
# We start by loading the list of existing ApplicationSpec records.
#

my $app_spec_data = $dbh->selectall_hashref(qq(SELECT id, application_id
					       FROM ApplicationSpec), 'id');
my $first_id;

if ($opt->first_record)
{
    $first_id = $opt->first_record;
}
else
{
    #
    # The following query will be fast since it can make it entirely from the index.
    # It is much more expensive to add the filter on the end-date of archiving, so
    # we make that test in code.
    #
    my $res = $dbh->selectcol_arrayref(qq(SELECT min(id) FROM Task));
    $res or die "Failed to find minimum task id: $@\n";
    $first_id = $res->[0];
    
    print "First id is $first_id\n";
    
    #
    # Find the last archived ID. If we are incrementally archiving without
    # deleting records we will want to start with the latest archived + 1.
    #
    my $res = $dbh->selectcol_arrayref(qq(SELECT max(id) FROM ArchivedTask));
    $res or die "Failed to find max archived task id: $@\n";
    my $last_archived_id = $res->[0];
    
    print "Last archived id is $last_archived_id\n";

    $first_id = $last_archived_id + 1 if $last_archived_id;
}

my $max_id;
if ($opt->max_records)
{
    $max_id = $first_id + $opt->max_records - 1;
}

my $continue;
do
{
    my $last_id = $first_id + $opt->batch_size - 1;
    $last_id = $max_id if $max_id && $last_id > $max_id;

    $continue = process_block($first_id, $last_id);

    $first_id += $opt->batch_size;
    # print "XXX $continue $first_id $max_id\n";
}
while ($continue && (!$max_id || $first_id <= $max_id)) ;

sub process_block
{
    my($first_id, $last_id) = @_;

    print "Process $first_id - $last_id\n";

    $dbh->begin_work;

    my $sth = $dbh->prepare(qq(INSERT INTO ArchivedTask ($archive_task_fields, cluster_job_id, active,
							 cluster_id, job_id, job_status, maxrss, nodelist, exitcode)
			       VALUE ($archive_task_qs,
				      ?, ?,
				      ?, ?, ?, ?, ?, ?)));

    my $tasks = $dbh->selectall_hashref(qq(SELECT submit_time < ? AS valid_for_archiving, $task_fields
					   FROM Task
					   WHERE id >= ? AND id <= ?), 'id', undef,
					$end_date, $first_id, $last_id);
    #
    # We need to check the returned records for tasks that
    # are past our end date. Those end the overall process. Since we are querying by
    # chunk and it is possible for tasks to be missing, we can't use an empty
    # result from the query to end the toplevel loop.
    #

    my $continue = 1;
    while (my($id, $h) = each %$tasks)
    {
	if (!$h->{valid_for_archiving})
	{
	    $continue = 0;
	    last;
	}
    }
    
    my @cjfields = qq(task_id cluster_job_id active cluster_id job_id job_status maxrss nodelist exitcode);
    #
    # We use this query to both find the TaskExecution records and the ClusterJob records for deletion;
    # we also query back through to TaskExecution again to pick up the case where
    # multiple Tasks have been grouped in a single ClusterJob.
    #
    # Nix that. The added data clutters the logic below so we will make a second query to get exactly
    # what we are looking for. Performance is not a huge issue here since this is a background
    # procedure.
    #
    my $cluster_jobs = $dbh->selectall_arrayref(qq(SELECT te.task_id, te.cluster_job_id, te.active,
						   cj.cluster_id, cj.job_id, cj.job_status, cj.maxrss, cj.nodelist, cj.exitcode
						   FROM ClusterJob cj JOIN TaskExecution te on cj.id = te.cluster_job_id
						   WHERE te.task_id >= ? AND te.task_id <= ?
						   ORDER BY te.task_id),
						undef, $first_id, $last_id);

    #
    # We need to determine if any of these jobs is a parent for a subsequent job. If so we can't delete it yet.
    #
    my $child_tasks = $dbh->selectall_arrayref(qq(SELECT id, parent_task
						  FROM Task
						  WHERE parent_task >= ? AND parent_task <= ?), undef, $first_id, $last_id);
    my %child_tasks;
    push(@{$child_tasks{$_->[1]}}, $_->[0]) foreach @$child_tasks;
    # print Dumper(child_tasks => \%child_tasks);

    #
    # Now walk the task list with a separate index on the cluster jobs to denormalize.
    # We did one level of denormalizing with the second query.
    #
    
    my $cj_idx = 0;

    #
    # The following are the IDs we actually archived, and will be deleting if delete is enabled.
    #
    my @task_ids;
    my @cj_ids;
    my %task_cjs;
    my %task_cj_extra_tasks;
    
    my $extra_sth = $dbh->prepare(qq(SELECT task_id
				     FROM TaskExecution
				     WHERE cluster_job_id = ? AND task_id != ?));

    for my $task_id ($first_id .. $last_id)
    {
	my $task = $tasks->{$task_id};
	next unless $task;
	next unless $task->{valid_for_archiving};
	
	# print "$task_id $task->{application_id} $task->{submit_time}\n";

	#
	# Collect the cj data associated with this task.
	# We do this separately from emitting the records because
	# we need to be prepared to archive a task with no associated records.
	#

	my @task_cjs;
	
	#
	# Handle a skip in the task sequence.
	#
	while ($cluster_jobs->[$cj_idx] && $cluster_jobs->[$cj_idx]->[0] < $task_id)
	{
	    # print "incr $task_id $cluster_jobs->[$cj_idx]->[0] $cj_idx\n";
	    $cj_idx++;
	}
	
	while ($cluster_jobs->[$cj_idx]->[0] == $task_id)
	{
	    push(@task_cjs, $cluster_jobs->[$cj_idx]);
	    push(@{$task_cjs{$task_id}}, $cluster_jobs->[$cj_idx]->[1]);
	    $cj_idx++;
	}

	#
	# Prepare for insertion into archive.
	# First we determine the appropriate application spec id.
	# We also parse the params to ensure it is valid JSON since we
	# are inserting into a JSON field. If it does not we just insert a blank
	# object - {}. 
	#

	my $params_data = eval { decode_json($task->{params}) };
	if (!$params_data)
	{
	    # print "$task_id failed to parse params, inserting blank\n";
	    $task->{params} = "{}";
	}

	my $app_spec_id;

	if (defined($task->{app_spec}))
	{
	    $app_spec_id = eval { lookup_spec($dbh, $app_spec_data, $task->{application_id}, $task->{app_spec}, $task->{submit_time}); };
	    if ($@)
	    {
		die Dumper($task) . ": Error creating spec $@";
	    }
	}
	$task->{app_spec_id} = $app_spec_id;

	#
	# If there are no cluster jobs, push an empty array to the list so we
	# emit the single row with empty cluster job data.
	#
	if (@task_cjs == 0)
	{
	    push(@task_cjs, []);
	}
	    
	#
	# Here we have a validated app spec id and the corrected list of cluster jobs.
	# We can write our archive record.
	#

	# print Dumper($task_id, $app_spec_id, \@task_cjs);

	push(@task_ids, $task_id);

	$task->{retry_index} = 0;
	for my $cj (@task_cjs)
	{
	    my($task_id, $cluster_job_id, $active, $cluster_id, $job_id, $job_status, $maxrss, $nodelist, $exitcode) = @$cj;

	    #
	    # Look for additional tasks that might be linked to this ClusterJob.
	    # If there are any, we can't try to delete the ClusterJob entry yet.
	    #
	    $extra_sth->execute($cluster_job_id, $task_id);
	    $task_cj_extra_tasks{$task_id, $cluster_job_id} = $extra_sth->fetchall_arrayref();
		
	    if (defined($cluster_job_id))
	    {
		push(@cj_ids, $cluster_job_id);
	    }
	    $sth->execute(@$task{@archive_task_fields},
			  $cluster_job_id, $active,
			  $cluster_id, $job_id, $job_status, $maxrss, $nodelist, $exitcode);
	    $task->{retry_index}++;

	}
	    


#	print "BOT $task_id\n";
    }

    if ($opt->delete)
    {
	if (@task_ids)
	{
	    my $task_ids = join(",", @task_ids);
	    # print Dumper(\%task_cjs);
	    for my $task_id (@task_ids)
	    {
		my $cjs = $task_cjs{$task_id};

		if ($cjs && @$cjs)
		{
		    my $cjs_str = join(",", @$cjs);
		    
		    # print "Delete TaskExecution t=$task_id $cjs_str\n";
		    $dbh->do(qq(DELETE FROM TaskExecution WHERE task_id = ? and cluster_job_id IN ($cjs_str)), undef, $task_id);

		    #
		    # If there were other tasks associated with the cluster job, don't try to delete this here.
		    #
		    my @del;
		    for my $cj (@$cjs)
		    {
			my $extra = $task_cj_extra_tasks{$task_id, $cj};
			if (@$extra)
			{
			    my @list = map { $_->[0] } @$extra;
			    # print "Deferring deletion of ClusterJob $cj due to other tasks @list\n";
			}
			else
			{
			    push(@del, $cj);
			}
		    }
		    if (@del)
		    {
			my $del = join(",", @del);
			# print "Delete ClusterJobs @del\n";
			$dbh->do(qq(DELETE FROM ClusterJob WHERE id IN ($del)));
		    }
		}
		else
		{
		    warn "No CJ for $task_id\n";
		}
	    }
	    #
	    # We don't need the saved tokens any more. When we archive we lose the
	    # ability to rerun a job.
	    #
	    # print "Delete task tokens $task_ids\n";
	    $dbh->do(qq(DELETE FROM TaskToken WHERE task_id IN ($task_ids)));

	    #
	    # We cannot delete this task if it is parent for something else.
	    #

	    for my $task_id (@task_ids)
	    {
		if ($child_tasks{$task_id} && @{$child_tasks{$task_id}})
		{
		    print "Defer deletion of task parent $task_id due to @{$child_tasks{$task_id}}\n";
		}
		else
		{
		    # print "Delete task $task_id\n";
		    $dbh->do(qq(DELETE FROM Task WHERE id = ?), undef, $task_id);
		}

		my $parent = $tasks->{$task_id}->{parent_task};

		if ($parent)
		{
		    #
		    # If this task has a parent, and there are no siblings, delete the parent.
		    # 
		    my $siblings = $dbh->selectall_arrayref(qq(SELECT id
							       FROM Task t 
							       WHERE parent_task = ?), undef, $parent);
		    # print Dumper($task_id, $siblings);
		    if (@$siblings == 0)
		    {
			# print "Delete task parent $parent\n";
			$dbh->do(qq(DELETE FROM Task WHERE id = ?), undef, $parent);
		    }
		}

	    }
	}
	else
	{
	    warn "No tasks found to delete\n";
	}
    }
		


#     print "RET $continue\n";


    $dbh->commit;
    return $continue;
}

sub lookup_spec
{
    my($dbh, $data, $app_id, $spec, $sub_time) = @_;

    #
    # Compute SHA-256, and look up. Add new if necessary.
    #

    my $sha = sha256_hex($spec);
    my $cur = $data->{$sha};
    if (defined($cur))
    {
	if ($cur->{application_id} ne $app_id)
	{
	    die "INVALID APP ID $sha $cur->{application_id} $app_id " . Dumper($spec);
	}
    }
    else
    {
	#
	# Validate the json.
	#
	my $d = eval { $json->decode($spec); };
	if (!$d)
	{
	    print STDERR "Invalid spec for $app_id $sub_time\n";
	    $spec = "{}";
	}
	$dbh->do(qq(INSERT INTO ApplicationSpec (id, application_id, spec, first_seen) VALUES (?, ?, ?, ?)),
		 undef, $sha, $app_id, $spec, $sub_time);
	$data->{$sha} = { id => $sha, application_id => $app_id };
    }
    return $sha;
}

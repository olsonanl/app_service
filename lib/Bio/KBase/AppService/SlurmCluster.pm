package Bio::KBase::AppService::SlurmCluster;

use 5.010;
use strict;
use Template;
use Module::Metadata;
use Bio::KBase::AppService::Schema;
use Bio::KBase::AppService::AppConfig qw(slurm_control_task_partition app_service_url);
use base 'Class::Accessor';
use Data::Dumper;
use Try::Tiny;
use DateTime;
use EV;
use AnyEvent;
use JSON::XS;
use File::Basename;
use File::SearchPath qw(searchpath);
use File::Path qw(make_path);
use IPC::Run qw(run);
use IO::Handle;
use List::Util qw(max);

__PACKAGE__->mk_accessors(qw(id schema json slurm_path scheduler
			    ));

# value is true if it is a terminal state; the value is the
# TaskState code for that terminal state

our %job_states =
    (
     BOOT_FAIL => 'F',
     CANCELLED => 'F',
     COMPLETED => 'C',
     DEADLINE => 'F',
     FAILED => 'F',
     NODE_FAIL => 'F',
     OUT_OF_MEMORY => 'F',
     PENDING => 0,
     PREEMPTED => 0,
     RUNNING => 0,
     REQUEUED => 0,
     RESIZING => 0,
     REVOKED => 'F',
     SUSPENDED => 0,
     TIMEOUT => 'F',
    );

=head1 NAME

Bio::KBase::AppService::SlurmCluster - cluster wrapper for SLURM submissions

=head1 SYNOPSIS

    $slurm = Bio::KBase::AppService::SlurmCluster->new($cluster_id, schema => $schema)

=head1 DESCRIPTION

A SlurmCluster instance represents a particular SLURM cluster in the infrastructure.

The scheduler database maintains a record for each cluster; at this point the only
metadata kept in the database are the cluster name and the base path of the 
installation on the filesystem. This is sufficient to submit to a SLURM cluster.

=head1 USER ACCOUNTING

In this architecture each submission to SLURM requires a SLURM account. The account
name represents the user account from the submitting web service (PATRIC or RAST). 

PATRIC account names are suffixed with @patricbrc.org as they come in from the PATRIC
accounting system.

Submissions with account names without a prefix will have @rast.nmpdr.org added.

All web service jobs will execute under Unix run account that the service is executing
under. 

If the account is not known to the SLURM account manager, a new account will be created.

We have the following account hierarchy defined:

   webservice
   +-- PATRIC
       +-- user1@patricbrc.org
       +-- user2@patricbrc.org
       +-- ...
   +-- RAST
       +-- user3@rast.nmpdr.org
       +- ...

=head1 MISCELLANY

We force the setting of TZ=UCT before running Slurm commands so that we can consistently
log times reported in UCT.

=head2 METHODS

=over 4

=item B<new>

    $cluster = Bio::KBase::AppService::SlurmCluster->new($id, schema => $schema, %opts)

=over 4

=item Arguments: $id, L<$schema|Bio::KBase::AppService::Schema>

=item Return Value: L<$cluster|Bio::KBase::AppService::SlurmCluster>

=back

Create a new SlurmCluster object. The given C<$id> must exist in the database. C<$schema> is a 
pointer to the DBIx::Class schema for the database.

=cut

sub new
{
    my($class, $id, %opts) = @_;

    #
    # Find sacctmgr in our path to set our slurm_path.
    #

    my $schema = $opts{schema};
    $schema or die "SlurmCluster: schema parameter is required";

    my $cobj = $schema->resultset("Cluster")->find($id);
    $cobj or die "Cannot find cluster $id in database";

    #
    # Set up accountmgr features if we don't have a fixed account
    # to use for this cluster.
    #

    my $slurm_path;
    if (!$cobj->account)
    {
	my $path = $cobj->scheduler_install_path;
	if ($path)
	{
	    $slurm_path = "$path/bin";
	}
	else
	{
	    my $p = searchpath('sacctmgr');
	    if ($p)
	    {
		$slurm_path = dirname($p);
	    }
	    else
	    {
		die "Cannot find slurm executables in $ENV{PATH}";
	    }
	}
    }

    print STDERR "Using slurm path $slurm_path\n";

    my $self = {
	id => $id,
	json => JSON::XS->new->pretty(1)->canonical(1),
	slurm_path => $slurm_path,
	%opts,
    };

    #
    # Look up and cache task codes.
    #

    my $rs = $schema->resultset('TaskState');
    $rs->result_class('DBIx::Class::ResultClass::HashRefInflator');
    while (my $s = $rs->next)
    {
	$self->{code_description}->{$s->{code}} = $s->{description};
    }
	

    return bless $self, $class;
}

=item B<configure_user>

    $cluster->configure_user($user)

=over 4

=item Arguments: L<$user|Bio::KBase::AppService::Schema::Result::ServiceUser>

=back

Configure accounting for the provided new user.

=cut

sub configure_user
{
    my($self, $user) = @_;


    if (!ref($user))
    {
	$user = $self->schema->resultset("ServiceUser")->find($user);
	die "Cannot find user $user\n" unless $user;
    }

    my $cinfo = $self->schema->resultset("Cluster")->find($self->id);

    return if $cinfo->account;

    #
    # We will want to do this across the configured clusters.
    # For now, don't worry about it to make things run again.
    #
    my $cluster = "patric";
    
    #
    # We don't do a check to see if slurm has the user; we are likely only
    # coming here when a submission failed due to the lack of an account.
    #
    my $desc = "";
    if ($user->first_name)
    {
	$desc = $user->first_name . " " . $user->last_name;
    }
    $desc .= " <" . $user->email . ">" if $user->email;

    #
    # Attempt to add the account.
    #
    my @cmd = ($self->slurm_path . "/sacctmgr", "-i",
	       "create", "account",
	       "name=" . $user->id,
	       "fairshare=1",
	       "cluster=$cluster",
	       "parent=" . $user->project_id,
	       ($desc ? ("description=$desc") : ()),,
	       ($user->affiliation ? ("organization=" . $user->affiliation) : ()),
	       );
    my($stderr, $stdout);
    print STDERR "@cmd\n";
    my $ok = run(\@cmd, ">", \$stderr, "2>", \$stdout);
    if ($ok)
    {
	print STDERR "Account created: $stdout\n";
    }
    elsif ($stderr =~ /Nothing new added/)
    {
	print STDERR "Account " . $user->id . " apparently already present\n";
    }
    else
    {
	warn "Failed to add account " . $user->id . ": $stderr\n";
    }
	
    #
    # Ensure the current user has access to this new account.
    #
    @cmd = ($self->slurm_path . "/sacctmgr", "-i",
	    "add", "user", $ENV{USER},
	    "cluster=$cluster",
	    "Account=" . $user->id);
    $ok = run(\@cmd,
	      "2>", \$stderr);
    if (!$ok)
    {
	warn "Error $? adding account " . $user->id . " to user $ENV{USER} via @cmd\n$stderr\n";
    }

    #
    # Check the status of the created account. Perhaps this will help
    # with what seems to be a race condition on the first job run for
    # a newly created account.
    #
    @cmd = ($self->slurm_path . "/sacctmgr", 
	    "show", "account", $user->id);
    $ok = run(\@cmd, "1>&2");
    
    @cmd = ($self->slurm_path . "/sacctmgr", 
	    "show", "association",
	    "Account=" . $user->id);
    $ok = run(\@cmd, "1>&2");
}

=item B<submit_tasks>

    $ok = $cluster->submit_tasks($tasks, $resources)

=over 4

=item Arguments: L<\@tasks|Bio::KBase::AppService::Schema::Result::Task>, \@resources

=item Return value: $status
    
=back

Submit a set of tasks to the cluster.  Returns true if the tasks were submitted. As a side effect
create the L<ClusterJob|Bio::KBase::AppService::Schema::Result::ClusterJob> record for
this task.

All tasks are created in the same cluster job. This logic enables sharing of a single
cluster submission for multiple pieces of work where there is a disconnect between the size
of the smallest possible resource request at the cluster and the maximum amount of CPU
a task can utilize.

If multiple tasks are submitted, we do not use the memory/cpu requirements from
the task; rather we rely on the C<$resources> list which includes the 
sbatch request options required for this submission. (Yes, we are punting here.
This is mostly for the special case of submitting set of tasks to a single node
on a large cluster, where we have cluster-specific options for requesting such a node).

For the submission, we create a batch script with the following options

=over 4

=item --account  account-name

Name of user account for this submission.

=item --job-name task-id

Name the job by the task id.

=item --mem required-memory

Request the given amount of RAM.

=item --ntasks tasks --cpus-per-task 1

Request the given number of tasks (cpus).

=item --output output-file

=item --error error-file

Specify the location of standard output and standard error logging.

These are paths on the execution host; for now we will assume a common location
(L<< $self->exec_host_output_dir >>).

Slurm does not set any policy for us and will notably drop the job
into the working directory of the invoking script or into a
directory defined by the --chdir flag.

=back
    
=head2 ENVIRONMENT SETUP

We use the p3_deployment_path field on the Cluster from the database to find
the deployment to use.  For now we will inline in the startup script the
appropriate environment setup.

We must define for the invoked application the CPU and memory allocation
provided for it. In some cases this comes from the Slurm allocation, in others
(e.g. Bebop) it is a defined fraction of the node resources. In the
latter case we must compute that available resource by querying the node.

In that case, we use C<nproc> to determine processor count and a parse
of the C<free> command to determine available memory.

These parameters are passed to the application by the P3_ALLOCATED_CPU and 
P3_ALLOCATED_MEMORY environment variables.

=cut

sub submit_tasks
{
    my($self, $tasks) = @_;

    return if @$tasks == 0;
    
    my($account, $batch, $name) = $self->build_submission_for_tasks($tasks);
    
    # print $batch;
    print "Submit tasks for $account\n";

    if (open(FTMP, ">", "batch_tmp/task-" . $tasks->[0]->id))
    {
	print FTMP $batch;
	close(FTMP);
    }

    #
    # Run the submit.
    # We need to handle the following possible errors:
    #
    #    Account is not valid:
    #	   sbatch: error: Batch job submission failed: Invalid account or account/partition combination specified
    #    Here, we will use $self->configure_user to create the account and rerun the submission. If
    #    it fails again, register a hard failure on the job.
    #
    #    ssh failures:
    #	 If we are submitting via ssh and the target system is not available, we will just
    #    skip this job and let it retry later.
    #
    # Timeout on submission:
    #    Marking task 10393169 as failed due to sbatch: error: Batch job submission failed: Socket timed out on send/recv operation
    #
    # Here, we need to use squeue to query the scheduler to see if the job was actually started, and to
    # determine the slurm job id.
    #
    # Otherwise we mark the job as failed.
    #
    my($stdout, $stderr);
    my $cmd = $self->setup_cluster_command([$self->slurm_path . "/sbatch", "--parsable"]);

    my $submit = sub { run($cmd, "<", \$batch, ">", \$stdout, "2>", \$stderr,
			   init => sub { $ENV{TZ} = 'UCT'; });
		   };


    my $retrying = 0;
    my $ok;
    while (1)
    {
	$ok = &$submit();

	my($get_ok, $sub_jobid, $sub_account) = $self->lookup_name_in_queue($name);
	print "LOOKUP: ok=$ok get-ok=$get_ok sub_jobid=$sub_jobid sub_account=$sub_account\n";

	if ($ok && $stdout =~ /^(\d+)/)
	{
	    my $id = $1;
	    $self->update_for_submitted_tasks($tasks, $id);
	    last;
	}
	else
	{
	    my $err = $?;

	    #
	    # We only try once to remedy an invalid account error.
	    #
	    if ($stderr =~ /Invalid account/ && !$retrying)
	    {
		print STDERR "Invalid account, configuring user\n";
		$self->configure_user($account);
		#
		# And retry after a short sleep.
		# We are seeing occasional failures here that feel like a
		# data race between the creation of a new account and immediate
		# submission of a job.
		#
		sleep(5);
	    }
	    elsif ($cmd->[0] eq 'ssh' && ($err / 256) == 255)
	    {
		warn "Ssh failure; will leave task retryable\n";
		last;
	    }
	    elsif ($stderr =~ /Socket timed out/)
	    {
		if ($get_ok)
		{
		    print STDERR "We had a task falure $stderr but were able to find jobid=$sub_jobid for account $sub_account\n";
		    $self->update_for_submitted_tasks($tasks, $sub_jobid);
		    last;
		}
		else
		{
		    for my $task (@$tasks)
		    {
			print STDERR "Marking task " . $task->id . " as failed due to $stderr and task name lookup failed\n";
			$task->update({state_code => 'F'});
		    }
		    last;
		}
	    }
	    else
	    {
		for my $task (@$tasks)
		{
		    print STDERR "Marking task " . $task->id . " as failed due to $stderr\n";
		    $task->update({state_code => 'F'});
		}
		last;
	    }
	}
	$retrying = 1;
    }
    return $ok;
}

sub build_submission_for_tasks
{
    my($self, $tasks) = @_;

    my $cinfo = $self->schema->resultset("Cluster")->find($self->id);

    my $name = "t-" . join(",", map { $_->id } @$tasks);

    #
    # Ensure all of the tasks have the same owner, if we
    # are submitting to a cluster where we do not use a single account.
    #
    my $account = $cinfo->account;
    if (!$account)
    {
	$account = $tasks->[0]->owner->id;
	for my $task (@$tasks[1..$#$tasks])
	{
	    if ($account ne $task->owner->id)
	    {
		die "submit_tasks: Tasks in a set must all have the same owner on this cluster";
	    }
	}
    }

    #
    # Template vars. Populate this, then instantiate the template to submit.
    #

    my %vars = (resources => [],
		tasks => [],
		sbatch_account => $account,
		sbatch_job_name => $name,
	       );

    #
    # Determine the container for this task.
    # The envar P3_CONTAINER is a global override (initially this was the only
    # way to set the container, but when the container support was added to
    # the database we disabled the production use of it).
    #
    # If P3_CONTAINER is set, assume the file has been placed and that
    # a dynamic download is NOT to be attempted.
    #

    local $Data::Dumper::Maxdepth = 1;
    
    if ($ENV{P3_CONTAINER})
    {
	$vars{container_image} = $ENV{P3_CONTAINER};
	$vars{data_directory} = $ENV{P3_DATA_DIRECTORY};
    }
    else
    {
	#
	# If we do batching, we will need to fix the selection of container. Assume a single task for now.
	#
	my $task = $tasks->[0];
	my $base_url = $task->base_url;

	my $container = $task->container;
	if (!$container)
	{
	    #
	    # If we have a base url set, determine if we have a container defined for it.
	    #
	    if ($base_url)
	    {
		my $site_default = $self->schema->resultset("SiteDefaultContainer")->find($base_url);
		if ($site_default)
		{
		    $container = $site_default->default_container;
		}
	    }
	}
	$container //= $cinfo->default_container;
	if ($container)
	{
	    $vars{container_repo_url} = $cinfo->container_repo_url;
	    $vars{container_cache_dir} = $cinfo->container_cache_dir;
	    $vars{container_filename} = $container->filename;
	    $vars{container_image} = $cinfo->container_cache_dir . "/" . $container->filename;
	}
	
	#
	# Determine data container.
	#

	my $data_container = $task->get_column("data_container_id");
	if (!$data_container)
	{
	    #
	    # If we have a base url set, determine if we have a data container defined for it.
	    #
	    if ($base_url)
	    {
		my $site_default = $self->schema->resultset("SiteDefaultDataContainer")->find($base_url);
		if ($site_default)
		{
		    $data_container = $site_default->get_column("default_data_container_id");
		}
	    }
	}

	if (!$data_container)
	{
	    #
	    # See if we have a default data container defined for this cluster
	    #
	    $data_container = $cinfo->get_column("default_data_container_id");
	}

	if ($data_container)
	{
	    #
	    # Look up the data container in teh database to see if we have
	    # a filesystem path defined for it.
	    #
	    my $res = $self->schema->resultset("DataContainer")->find($data_container);
	    if (!$res)
	    {
		warn "No entry found in DataContainer for $data_container";
	    }
	    my $path = $res->name;
	    if ($path =~ m,^/,)
	    {
		#
		# We have one. Configure job for data directory.
		#
		$vars{data_directory} = $path;
	    }
	    else
	    {
		#
		# No path found. Use data container id.
		#
		
		$vars{data_container} = $data_container;
		$vars{data_container_search_path} = $cinfo->data_container_search_path;
	    }
	}
	else
	{
	    $vars{data_directory} = $cinfo->default_data_directory;
	}
    }

    #
    # compute resource request information.
    # $alloc_env sets the allocation environment vars for the batch
    #
    my $resources = $self->{resources};
    if (@$tasks > 1 || $resources)
    {
	push(@{$vars{resources}}, map { "#SBATCH $_" } @$resources);

	my $ntasks = @$tasks;
	$vars{p3_allocation} = <<EAL;
mem_total=`free -b | grep Mem | awk '{print \$2}'`
proc_total=`nproc`
export P3_ALLOCATED_MEMORY=`expr \$mem_total / $ntasks`
export P3_ALLOCATED_CPU=`expr \$proc_total / $ntasks`
EAL
    }
    else
    {
	my $task = $tasks->[0];
	my $app = $task->application;

	my $ram = $task->req_memory // $app->default_memory // "100G";
	my $cpu = $task->req_cpu // $app->default_cpu // 1;

	my $storage;
	eval {
	    my $doc = decode_json($task->params);
	    $storage = $doc->{_preflight}->{storage};
	};
	if ($@)
	{
	    warn "error parsing task " . $task->id . " params: $@";
	}
	my %constraint;
	#
	# For over 20G, force run on machines with NFS ("sim" feature. yeah I know).
	#
	if ($storage > 20_000_000_000)
	{
	    $constraint{sim} = 1;
	}
	print STDERR "Task " . $task->id . " storage: $storage. Constraint: " . Dumper(\%constraint);

	$vars{sbatch_job_mem} = $ram;
	$vars{n_cpus} = $cpu;

	#
	# Choose a partition.
	#
	# We have a configuration option for a partition for the "control tasks" that
	# spend most of their time waiting. If the task is flagged as one, use the
	# configured control partition.
	#
	# If the task policy setting specifies a partition, use that.
	#
	# Otherwise, if the cluster configuration defines a submit_queue use that.
	#
	# Additionally, if the cluster configuration defines a submit_cluster
	# specify that.
	#

	my $policy = {};
	if (my $dat = $task->req_policy_data)
	{
	    $policy = eval { decode_json($dat); };
	    if (ref($policy) ne 'HASH')
	    {
		$policy = {};
	    }
	}
	
	if ($task->req_is_control_task)
	{
	    $vars{sbatch_partition} = "#SBATCH --oversubscribe --partition " . slurm_control_task_partition;
	}
	elsif ($policy->{partition})
	{
	    $vars{sbatch_partition} = "#SBATCH --partition $policy->{partition}";
	}
	elsif ($cinfo->submit_queue)
	{
	    $vars{sbatch_partition} = "#SBATCH --partition " . $cinfo->submit_queue;
	}
	if ($cinfo->submit_cluster)
	{
	    $vars{sbatch_clusters} = "#SBATCH --clusters " . $cinfo->submit_cluster;
	}

	$vars{sbatch_reservation} = $policy->{reservation};
	if (my $c = $policy->{constraint})
	{
	    $constraint{$_} = 1 foreach $c =~ /\w+/g;
	    if (%constraint)
	    {
		$vars{sbatch_constraint} = "#SBATCH --constraint " . join("&", keys %constraint);
	    }
	}
    }
    
    my $time = max map { int($_->req_runtime / 60) } @$tasks;
    # factor in slowdown.
    $time *= @$tasks;

    my $out_dir = $cinfo->temp_path;
    my $out = "$out_dir/slurm-%j.out";
    my $err = "$out_dir/slurm-%j.err";
    if ($cinfo->remote_host)
    {
	$out = "slurm-%j.out";
	$err = "slurm-%j.err";
    }

    $vars{sbatch_output} = $out;
    $vars{sbatch_error} = $err;
    $vars{sbatch_time} = $time;

    my $top = $cinfo->p3_deployment_path;
    my $rt = $cinfo->p3_runtime_path;

    # print STDERR "CLUSTER: top=$top rt=$rt\n";
    my $temp = $vars{cluster_temp} = $cinfo->temp_path;

    $vars{configure_deployment} = <<END;
export KB_TOP=$top
export KB_RUNTIME=$rt
export PATH=\$KB_TOP/bin:\$KB_RUNTIME/bin:\$PATH
export PERL5LIB=\$KB_TOP/lib
export KB_DEPLOYMENT_CONFIG=\$KB_TOP/deployment.cfg
export R_LIBS=\$KB_TOP/lib

export PATH=\$PATH:\$KB_TOP/services/genome_annotation/bin
export PATH=\$PATH:\$KB_TOP/services/cdmi_api/bin

export PERL_LWP_SSL_VERIFY_HOSTNAME=0

export TEMPDIR=$temp
export TMPDIR=$temp

END

    if ($self->{environment_config})
    {
	$vars{environment_config} = $self->{environment_config};
    }

    if (1 || $account eq 'olson@patricbrc.org')
    {
	push(@{$vars{environment_config}}, "export P3_CGA_TASKS_INLINE=1");
    }


    #
    # Configure a task var for each task and add to template variables.
    #
    for my $task (@$tasks)
    {
	my $appserv_url = $task->monitor_url;
	$appserv_url =~ s,/task_info,,;

	# hack
	# $appserv_url = "http://holly.mcs.anl.gov:5001";
	# $appserv_url = "http://p3.theseed.org/services_test/app_service_test";
	$appserv_url = app_service_url;

	my $token_obj = $task->task_tokens->search(undef, { order_by => {-desc => 'expiration '}})->single();
	if (!$token_obj)
	{
	    warn "Cannot find token for task " . $task->id . "\n";
	    $task->update( { state_code => 'F' });
	    next;
	}

	my $tvar = {
	    id => $task->id,
	    app => $task->application,
	    script => $task->application->script,
	    spec => $task->app_spec,
	    params => $task->params,
	    # use the token with the longest expiration
	    token => $token_obj->token,
	    monitor_url => $task->monitor_url,
	    appserv_url => $appserv_url,
	    base_url => $task->base_url,
	};
		
	push(@{$vars{tasks}}, $tvar);
    }


    #
    # Instantiate the template.
    #
    my $mod_path = dirname(Module::Metadata->find_module_by_name(__PACKAGE__));
    my $templ = Template->new(INCLUDE_PATH => $mod_path);
    # print "INCLUDE $mod_path\n";
    my $templ_file = "slurm_batch.tt";
    my $template_path = "$mod_path/$templ_file";
    -f $template_path or die "Cannot find slurm batch template at $template_path";

    my $batch;

    my $ok = $templ->process($templ_file, \%vars, \$batch);
    if (!$ok)
    {
	die "Error processing template $templ_file: " . $templ->error() . "\n" . Dumper(\%vars);
    }

    return($account, $batch, $name);
}




=item B<update_for_submitted_tasks>
    
    $self->update_for_submitted_tasks($tasks, $id)

Update the database records for the tasks in $tasks to mark
they are submitted to this cluster with job id $id.

=cut

sub update_for_submitted_tasks
{
    my($self, $tasks, $id) = @_;

    my @taskids = map { $_->id } @$tasks;
    my $owner = $tasks->[0]->owner->id;
    print STDERR "Batch submitted with id $id for owner $owner and tasks @taskids\n";
    for my $task (@$tasks)
    {
	$task->update({state_code => 'S'});
	$task->add_to_cluster_jobs(
			       {
				   cluster_id => $self->id,
				   job_id => $id,
			       },
			       {
				   active => 1,
			       });
	# For the case where we don't have the M:M table
	# $task->create_related('cluster_jobs',
	# 		      { 
	# 			  cluster_id => $self->id,
	# 			  job_id => $id,
	# 			  active => 1,
	# 		      });
    }
}

=item B<submission_allowed>

    $ok =$cluster->submission_allowed()

Determine if submission is allowed now. At the least, the number of
jobs that we have submitted needs to be below the maximum allowed by the
cluster configuration.

=cut

sub submission_allowed
{
    my($self) = @_;

    my $cinfo = $self->schema->resultset("Cluster")->find($self->id);
    my $max_allowed = $cinfo->max_allowed_jobs();

    my $qc = $self->queue_count('S');
    my $ok = $qc < $max_allowed ? 1 : 0;
    print STDERR "submission_allowed: max=$max_allowed qc=$qc ok=$ok\n";
    return $ok;
}

=item B<queue_count>

    $cluster->queue_count($status)

Check the count of jobs in the queue in with the given task status.

=cut

sub queue_count
{
    my($self, $state) = @_;
    my $count = $self->schema->resultset("ClusterJob")->search({
	cluster_id => $self->id,
	'task.state_code' => $state,
	'task_executions.active' => 1,
    }, { join => { task_executions => 'task' }, distinct => 1})
	->count();

    return $count;
}

=item B<queue_check>

    $cluster->queue_check()

Check and update the status of any queued jobs.

=cut

sub queue_check
{
    my($self) = @_;

    #
    # We need to find the jobs on the cluster for which the state
    # of the associated tasks(s) is S (Submitted to cluster). There may
    # be multiples because the scheduler may have run multiple tasks
    # in a single job in order to share resources.
    #
    # Query distinct here to get the set of cluster jobs. We will
    # update state on all associated tasks. (This may obscure
    # reporting of real execution times for the tasks, but we cannot
    # know that here. Such reporting must be done at either the
    # level of the app-wrapping scripts or the submitted
    # scheduler batch script).
    #

    my @jobs = $self->schema->resultset("ClusterJob")->search({
	cluster_id => $self->id,
	'task.state_code' => 'S',
	'task_executions.active' => 1,
    }, { join => { task_executions => 'task' }, distinct => 1});

    if (@jobs == 0)
    {
	print STDERR "No jobs\n";
	return;
    }

    my $jobspec = join(",", map { $_->job_id } @jobs);

    #
    # We can use sacct to pull data from all jobs, including currently running.
    # We can thus get all data in a single lookup.
    #

    my @params = qw(JobID State Account User MaxRSS ExitCode Elapsed Start End NodeList);
    my %col = map { $params[$_] => $_ } 0..$#params;

    my @cmd = ($self->slurm_path . '/sacct', '-j', $jobspec,
	       '-o', join(",", @params),
	       '--units', 'M',
	       '--parsable', '--noheader');
    my $fh = IO::Handle->new;
    my $h = IPC::Run::start($self->setup_cluster_command(\@cmd), '>pipe', $fh,
			    init => sub { $ENV{TZ} = 'UCT'; });
    if (!$h)
    {
	warn "Error $? checking queue : @cmd\n";
	return;
    }

    my %jobinfo;

    #
    # To integrate data from the "id" and "id.batch" lines we read all data first.
    # Pull job state and start times from "id" lines, the other data from "id.batch"
    #

    while (<$fh>)
    {
	chomp;
	my @a = split(/\|/);
	my %vals = map { $_ => $a[$col{$_}] } @params;
	my($id, $isbatch) = $vals{JobID}  =~ /(\d+)(\.batch)?/;
	# print STDERR "$id: " . Dumper(\%vals);

	if ($isbatch)
	{
	    $jobinfo{$id} = { %vals };
	}
	else
	{
	    $jobinfo{$id}->{Start} = $vals{Start} unless $vals{Start} eq 'Unknown';
	    $jobinfo{$id}->{State} = $vals{State};
	    $jobinfo{$id}->{NodeList} = $vals{NodeList};
	}
    }
    # print STDERR Dumper(\%jobinfo);

    if (!$h->finish)
    {
	warn "Error $? on sstat\n";
    }
    
    for my $cj (@jobs)
    {
	my $job_id = $cj->job_id;
	my $vals = $jobinfo{$job_id};

	#
	# Code is true if the new job state is a terminal state.
	# Pull final results.
	# Use the first word of the state since we have 'CANCELLED by 424'
	#
	my ($s1) = $vals->{State} =~ /^(\S+)/;
	my $code = $job_states{$s1};
	if ($code)
	{
	    my($rss) = $vals->{MaxRSS} =~ /(.*)M$/;
	    $rss = 0 if $vals->{MaxRSS} == 0;

	    print STDERR "Job $job_id done " . Dumper($vals);
	    $cj->update({
		job_status => $vals->{State},
		maxrss => $rss,
		exitcode => $vals->{ExitCode},
		($vals->{NodeList} ne '' ? (nodelist => $vals->{NodeList}) : ()),
	    });


	    #
	    # Update the associated tasks.
	    #
	    for my $task ($cj->tasks)
	    {
		$self->scheduler->invalidate_user_cache($task->owner);
		$task->update({
		    state_code => $code,
		    ($vals->{Start} =~ /\d+/ ? (start_time => $vals->{Start}) : ()),
		    ($vals->{End} =~ /\d+/ ? (finish_time => $vals->{End}) : ()),
		    search_terms => join(" ",
					 $task->owner,
					 $self->{code_description}->{$code},
					 $code,
					 $job_id,
					 $cj->cluster_id,
					 $task->output_path,
					 $task->output_file,
					 $task->application_id),
		});
	    }
	}
	else
	{
	    print STDERR "Job $job_id update " . Dumper($vals);
	    # job is still running; just update state and node info.
	    if ($cj->job_status ne $vals->{State})
	    {
		$cj->update({
		    job_status => $vals->{State},
		    ($vals->{NodeList} ne '' ? (nodelist => $vals->{NodeList}) : ()),
		});
		if ($vals->{Start})
		{
		    for my $task ($cj->tasks)
		    {
			$self->scheduler->invalidate_user_cache($task->owner);
			$task->update({
			    start_time => $vals->{Start},
			});
		    }
		}
	    }
	}
    }
}

=item B<kill_job>

=over 4

=item Arguments: $cluster_job

=back

Kill the job represented by $cluster_job. Uses scancel.

=cut

sub kill_job
{
    my($self, $cluster_job) = @_;

    my $cmd = $self->setup_cluster_command([$self->slurm_path . "/scancel", $cluster_job->job_id]);
    print STDERR "Run: @$cmd\n";
    my $ok = run($cmd);
    if (!$ok)
    {
	warn "Error $? from @$cmd\n";
    }
}

=item B<setup_cluster_command>

=over 4

=item Arguments: \@cmd

=item Return Value: \@modified_command

=back

If we are executing on a remote cluster, modify the given
command to be one that does a ssh to the cluster.

=cut

sub setup_cluster_command
{
    my($self, $cmd) = @_;

    my $cinfo = $self->schema->resultset("Cluster")->find($self->id);

    if ($cinfo->remote_host)
    {
	#
	# Need to invoke with bash -l to get login environment
	# configured, which gets the full setup required for e.g.
	# module command to work to manipulate environment.
	#
	my $shcmd = join(" ", map { "'$_'" } "env", "TZ=UCT", @$cmd);
	my $new = ["ssh",
		   "-l", $cinfo->remote_user,
		   "-i", $cinfo->remote_keyfile,
		   $cinfo->remote_host,
		   "bash -l -c \"$shcmd\"",
		   ];
	print STDERR "@$new\n";
	return $new;
    }
    else
    {
	return $cmd;
    }
	 
}

sub lookup_name_in_queue
{
    my($self, $name) = @_;
    
    my $cmd = $self->setup_cluster_command([$self->slurm_path . "/squeue",
					    "--noheader",
					    "--name", $name,
					    "-o", join("\t", qw(%j %i %a))]);
    my $tries = 5;
    while ($tries--)
    {
	my $out;
	my $err;
	my $ok = run($cmd, ">", \$out, "2>", \$err);
	if ($ok)
	{
	    chomp $out;
	    my($name, $jobid, $account) = split(/\t/, $out);

	    if ($jobid ne "")
	    {
		return(1, $jobid, $account);
	    }
	    else
	    {
		warn "Job lookup succeeded but returned empty jobid ($out)\n";
	    }
	}
	else
	{
	    warn "Error looking up job $name '$out' '$err'\n"; 
	}
	warn "Sleeping and retrying $tries\n";
	sleep(1);
    }
    warn "Failed to look up id after retries\n";
    return (0);
}


=back

=cut    


1;

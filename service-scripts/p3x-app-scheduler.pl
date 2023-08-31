use strict;
use Bio::KBase::AppService::Scheduler;
use Bio::KBase::AppService::SlurmCluster;
use Bio::KBase::AppService::AppSpecs;
use Bio::KBase::AppService::AppConfig qw(sched_db_host sched_db_port sched_db_user sched_db_pass sched_db_name
					 sched_default_cluster
					 app_directory app_service_url);

use IPC::Run 'run';
use Try::Tiny;
use AnyEvent;

use Getopt::Long::Descriptive;

my($opt, $usage) = describe_options("%c %o",
				    ["app-cache=s" => "Use this directory as the application specification cache directory"],
				    ["help|h" => "Show this help message."]);
print($usage->text), exit 0 if $opt->help;
die($usage->text) if @ARGV != 0;

my $specs = Bio::KBase::AppService::AppSpecs->new($opt->app_cache // app_directory);
my $sched = Bio::KBase::AppService::Scheduler->new(specs => $specs);
$sched->{task_start_disable} = 0;
$sched->load_apps();

my $cluster = Bio::KBase::AppService::SlurmCluster->new(sched_default_cluster,
							scheduler => $sched,
							schema => $sched->schema);

# my $shared_cluster = Bio::KBase::AppService::SlurmCluster->new('Bebop',
# 							scheduler => $sched,
# 							schema => $sched->schema,
# 							resources => ["-p bdws",
# 								      "-N 1",
# 								      "--ntasks-per-node 1",
# 								      "--time 1:00:00"]);
# my $bebop_cluster = Bio::KBase::AppService::SlurmCluster->new('Bebop',
# 							scheduler => $sched,
# 							schema => $sched->schema,
# 							resources => [
# 								      "-p bdwd",
# 								      "-x bdwd-0050",
# 								      # "-p bdwall",
# 								      "-N 1",
# 								      "-A PATRIC",
# 								      "--ntasks-per-node 1"],
# 							environment_config => ['module add jdk'], ['module add gnuplot']);





$sched->default_cluster($cluster);

$sched->start_timers();

my $run_cv = AnyEvent->condvar;
$run_cv->recv;

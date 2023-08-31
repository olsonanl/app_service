#
# Carefully clear temp space, retaining folders for active jobs.
#

use strict;
use Data::Dumper;

my $dur ="3d";
my @verbose = ("-v");

#@verbose = ();

my $cleaner = "/usr/bin/tmpwatch";
my $protect = "-x";
my $dirmtime = "--dirmtime";
if (! -x $cleaner)
{
    $cleaner = "/usr/sbin/tmpreaper";
    $protect = "--protect";
    $dirmtime = "--mtime-dir";
}
die "No tmpwatch or tmpreaper" if ! -x $cleaner;

my @save_paths = ("/disks/tmp/retain", "/disks/tmp/bob");

my $tasks = find_active_jobs();

#
# Create our stop list.
#

my @paths;
for my $ent (values %$tasks)
{
    my $path = "/disks/tmp/task-$ent->{task_id}-$ent->{slurm_id}";
    if (-d $path)
    {
	push(@paths, $path);
    }
    else
    {
	warn "Could not find task folder $path\n";
    }
}

my @cmd = ($cleaner,
	   @verbose,
	   $dur,
	   $dirmtime,
	   "-a",
	   (map { ($protect, $_) } @paths, @save_paths),
	   "/disks/tmp");

print "@cmd\n";

my $rc = system(@cmd);

$rc == 0 or die "Error $rc running @cmd: $!";

#
# We also clear the container cache.
#
system($cleaner, @verbose, $dur, "/disks/patric-common/container-cache");

sub find_active_jobs
{
    # Find our active task shepherds

    open(P, "-|", "ps", "-eo", "pid,ppid,cmd", "h") or die "Cannot run ps: $!";
    my %tasks;
    my %pid;
    my %kids;
    while (<P>)
    {
	chomp;
	my($pid, $ppid, $cmd) = /^\s*(\d+)\s+(\d+)\s+(.*)$/;
	die $_ if !$pid;
	if ($cmd =~ /p3x-app-shepherd.*--task-id\s+(\d+)/)
	{
	    $tasks{$1} = { pid => $pid, task_id => $1 };
	}
	$pid{$pid} = [$ppid, $cmd];
	push(@{$kids{$ppid}}, $pid);
    }
    close(P);
    
    #
    # Walk up the tree for our tasks, looking for a slurm invocation to find the slurm task id
    #

    for my $ent (values %tasks)
    {
	for (my $pid = $ent->{pid}; $pid != 1; $pid = $pid{$pid}->[0])
	{
	    my $cmd = $pid{$pid}->[1];
	    if ($cmd =~ m,slurm.*job(\d+)/,)
	    {
		$ent->{slurm_id} = $1;
		last;
	    }
	}
    }

    return \%tasks;
}

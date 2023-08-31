#
# Walk the process tree and purge any apps that are rooted at pid 1.
#

use Data::Dumper;
use strict;
use Proc::ProcessTable;
use POSIX;

my $table = Proc::ProcessTable->new;

my %kid_of;
my %pid_rec;

for my $ent (@{$table->table})
{
    push(@{$kid_of{$ent->{ppid}}}, $ent->{pid});
    $pid_rec{$ent->{pid}} = $ent;
}

my @to_check = @{$kid_of{1}};

my @apps = grep { $pid_rec{$_}->{cmndline} =~ /App|(java.*vigor)/ } @to_check;

print Dumper(@apps);

while (@apps)
{
    my $pid = shift(@apps);
    my $k = $kid_of{$pid};
    if ($k)
    {
	push(@apps, @{$kid_of{$pid}});
    }
    my $t = asctime(localtime $pid_rec{$pid}->{start});
    chomp $t;
    print "$pid\t$pid_rec{$pid}->{ppid}\t$t\t$pid_rec{$pid}->{cmndline}\n";
    my $ret = kill 1, $pid;
    $ret or warn "kill $pid: $!\n";
} 

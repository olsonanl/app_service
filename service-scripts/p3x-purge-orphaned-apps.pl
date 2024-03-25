#
# Walk the process tree and purge any apps that are rooted at pid 1.
#

use Data::Dumper;
use strict;
use Proc::ProcessTable;
use POSIX;
use Getopt::Long::Descriptive;

my($opt, $usage) = describe_options("%c %o",
				    ["check", "kill -0", { default => 0 }],
				    ["KILL|9", "kill -9", { default => 0 }],
				    ["help|h" => "show this help message"]);

print($usage->text), exit 0 if $opt->help;
die($usage->text) if @ARGV != 0;
my $signal = 1;

$signal = 9 if $opt->kill;
$signal = 0 if $opt->check;

my $table = Proc::ProcessTable->new;

my %kid_of;
my %pid_rec;

for my $ent (@{$table->table})
{
    push(@{$kid_of{$ent->{ppid}}}, $ent->{pid});
    $pid_rec{$ent->{pid}} = $ent;
}

my @to_check = @{$kid_of{1}};

my @apps = grep { $pid_rec{$_}->{cmndline} =~ /App|(java.*(pilon|vigor))|fasterq|mafft|hisat2|fftnsi/ } @to_check;

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
    my $ret = kill $signal, $pid;
    $ret or warn "kill $pid: $!\n";
} 

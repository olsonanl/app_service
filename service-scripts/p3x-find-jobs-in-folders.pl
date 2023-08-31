#
# Scan a folder hierarchy and look for the jobs found within.
#

use strict;
use Data::Dumper;
use P3DataAPI;
use Bio::P3::Workspace::WorkspaceClientExt;
use File::Path qw(make_path);
use File::Slurp;
use JSON::XS;

my $json = JSON::XS->new->canonical->pretty;

@ARGV == 3 or die "Usage: $0 ws-path new-path out-dir\n";

my $path = shift;
my $new_path = shift;
my $out_dir = shift;

my $ws = Bio::P3::Workspace::WorkspaceClientExt->new();

make_path($out_dir);

my $res = $ws->ls({ paths => [$path], excludeDirectories => 1, recursive => 1, query => { type => 'job_result' } });

$res = $res->{$path};

my $n = "01";

my $alt_path = '/ARWattam@patricbrc.org/home/AMR Workshop Examples';
for my $ent (@$res)
{
    my($name, $type, $obj_path, $created, $uuid, $owner, $size,
       $user_meta, $auto_meta, $user_perm, $global_perm, $shockurl) = @$ent;

    my $params = $auto_meta->{parameters};
    my $app = $auto_meta->{app};
    my $app_id = $app->{id};
    my $out_file = $params->{output_file};
    my $out_path = $params->{output_path};
    $out_path =~ s,^($path|$alt_path),, or die "Couldn't update path $out_path\n";
    $out_path = $new_path . $out_path;
    $params->{output_path} = $out_path;
    
    write_file("$out_dir/$n.app\n", $app_id);
    write_file("$out_dir/$n.json", $json->encode($params));

    $n++;
}

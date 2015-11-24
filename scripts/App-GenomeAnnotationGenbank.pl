#
# The Genome Annotation application. Genbank input variation.
#

use Bio::KBase::AppService::AppScript;
use Bio::KBase::AppService::GenomeAnnotationCore;
use Bio::KBase::AppService::AppConfig 'data_api_url';
use Bio::KBase::AuthToken;
use SolrAPI;

use strict;
use Data::Dumper;
use gjoseqlib;
use File::Basename;
use File::Slurp;
use File::Temp;
use LWP::UserAgent;
use JSON::XS;
use IPC::Run 'run';
use IO::File;

my $script = Bio::KBase::AppService::AppScript->new(\&process_genome);

my $rc = $script->run(\@ARGV);

exit $rc;

sub process_genome
{
    my($app, $app_def, $raw_params, $params) = @_;

    print "Proc genome ", Dumper($app_def, $raw_params, $params);

    my $core = Bio::KBase::AppService::GenomeAnnotationCore->new(app => $app,
								 app_def => $app_def,
								 params => $params);

    my $user_id = $core->user_id;

    #
    # Determine workspace paths for our input and output
    #

    my $ws = $app->workspace();

    my($input_path) = $params->{genbank_file};

    my $output_folder = $app->result_folder();

    my $output_base = $params->{output_file};

    if (!$output_base)
    {
	$output_base = basename($input_path);
    }

    #
    # Read genbank file data
    #
    # If the genbank file is compressed, uncompress and use that. Downstream
    # code in rast2solr needs the uncompressed data.
    #

    my $gb_temp = File::Temp->new();

    $ws->copy_files_to_handles(1, $core->token, [[$input_path, $gb_temp]]);
    
    my $genbank_data_fh;
    close($gb_temp);
    open($genbank_data_fh, "<", $gb_temp) or die "Cannot open contig temp $gb_temp: $!";

    #
    # Read first block to see if this is a gzipped file.
    #
    my $block;
    $genbank_data_fh->read($block, 256);

    my $gb_file;
    if ($block =~ /^\037\213/)
    {
	#
	# Gzipped. Uncompress into temp.
	#
	$gb_file = File::Temp->new();
	my $ok = run(["gunzip", "-d", "-c",  $gb_temp],
	    ">", $gb_file);
	$ok or die "Could not gunzip $gb_temp: $!";
	close($gb_file);
		
	close($genbank_data_fh);
	undef $genbank_data_fh;
	open($genbank_data_fh, "<", $gb_file) or die "Cannot open $gb_file: $!";
    }
    else
    {
	$genbank_data_fh->seek(0, 0);
	$gb_file = $gb_temp;
    }
    
    my $gb_data = read_file($genbank_data_fh);
    close($genbank_data_fh);
    
    my $genome = $core->impl->create_genome_from_genbank($gb_data);

    #
    # Add owner field from token
    #
    if ($core->user_id)
    {
	$genome->{owner} = $core->user_id;
    }

    my $result = $core->run_pipeline($genome);

    #
    # TODO fill in metadata?
    $core->write_output($genome, $result, {}, $gb_file);

    $core->ctx->stderr(undef);
}

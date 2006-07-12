#! /local/perl/bin/perl
BEGIN{foreach (@INC) {s/\/usr\/local\/packages/\/local\/platform/}};
use lib (@INC,$ENV{"PERL_MOD_DIR"});
no lib "$ENV{PERL_MOD_DIR}/i686-linux";
no lib ".";

=head1  NAME 

CogBsmlLoader.pl  -  Preprosess data stored in BSML pairwise alignment documents into BTAB
structure for COG analysis using best_hits.pl. 

=head1 SYNOPSIS

USAGE:  CogBsmlLoader.pl -m BsmlGeneModelDirectory -b BsmlPairwiseAlignmentDirectory -o OutputFile

=head1 OPTIONS

=over 4

=item *

B<--bsmlModelDir, -m>   [REQUIRED] Dir containing the BSML gene/sequence encodings referenced in the search directory

=item *

B<--bsmlSearchDir, -b>  [REQUIRED] Dir containing the BSML search encodings of pairwise alignments (all_vs_all, blastp)

=item *

B<--output, -o>        [REQUIRED] output BTAB file

=item *

B<--help,-h> This help message

=back

=head1   DESCRIPTION

CogBsmlLoader.pl is designed to preprocess the data contained in a BSML pairwise alignment search 
for COGS analysis. Specifically it identifies the "best hit" per genome for each query gene. 
This data is packaged into the BTAB format for linkage analysis using best_hits.pl  

NOTE:  

Calling the script name with NO flags/options or --help will display the syntax requirement.

=cut

# Preprosess data stored in BSML pairwise alignment documents into BTAB
# structure for COG analysis.

############
# Arguments:
#
# bsmlSearchDir - directory containing BSML pairwise sequence encodings
# bsmlModelDir - directory containing the BSML gene model documents for the search data
# outfile - btab output file
#
#

use strict;
use Getopt::Long qw(:config no_ignore_case no_auto_abbrev pass_through);
use Pod::Usage;
use Workflow::Logger;
use XML::Parser;

my %options = ();
my $results = GetOptions( \%options, 
			  'bsmlSearchList|b=s', 
			  'bsmlModelList|m=s', 
			  'bsmlJaccardList|j=s', 
			  'outfile|o=s', 
			  'pvalcut|p=s', 
			  'log|l=s',
			  'debug=s',
			  'help|h') || pod2usage();

my $logfile = $options{'log'} || Workflow::Logger::get_default_logfilename();
my $logger = new Workflow::Logger('LOG_FILE'=>$logfile,
				  'LOG_LEVEL'=>$options{'debug'});
$logger = Workflow::Logger::get_logger();

# display documentation
if( $options{'help'} ){
    pod2usage( {-exitval=>0, -verbose => 2, -output => \*STDERR} );
}


&check_parameters(\%options);

#MAIN HERE

# associative array to translate cds identifiers to polypeptide ids.
my $cds2Prot = {};

# If Jaccard data has been specified, use it for equivalence class filtering

my $jaccardClusterHash = {};  #Associate Jaccard clusters by sequence id
my $jaccardRepSeqHash = {};   #Associate a representative sequence for each cluster
my $jaccardClusterCount = 0;


$options{'bsmlJaccardList'} =~ s/\'//g;
$options{'bsmlJaccardList'} =~ s/\"//g;

if( $options{'bsmlJaccardList'} && $options{'bsmlJaccardList'} ne "" )
{
    if(-e $options{'bsmlJaccardList'}){

	my $seqCount=0;
	my $multihandlers = {'Alignment-summary'=>
				 sub {
				     $jaccardClusterCount++;
				 },
			     'Aligned-sequence'=>
				 sub {
				     my ($expat,$elt,%params) = @_;
				     my $name = $params{'name'};
				     $name =~ s/:[\d]*//;
				     # Associate a SeqId with a Jaccard Cluster ID
				     $jaccardClusterHash->{$name} = $jaccardClusterCount;
				     
				     # If this is the first sequence observed in the Jaccard Cluster
				     # identify it as the representative sequence and set it as the 
				     # representative sequence for the Jaccard Cluster ID.
				     
				     if( $seqCount == 0 )
				     {
					 $jaccardRepSeqHash->{$jaccardClusterCount} = [];
					 push @{$jaccardRepSeqHash->{$jaccardClusterCount}},$name;
				     }
				     else{
					 push @{$jaccardRepSeqHash->{$jaccardClusterCount}},$name;
				     }
				     $seqCount++;
				 }
			 };
	
	my $multiparser = new XML::Parser(Handlers => 
					  {
					      Start =>
						  sub {
						      #$_[1] is the name of the element
						      if(exists $multihandlers->{$_[1]}){
							  $multihandlers->{$_[1]}(@_);
						      }
						  }
					  }
					  );
	
	open JFILE, "$options{'bsmlJaccardList'}" or $logger->logdie("Can't open file $options{'bsmlJaccardList'}");
	while(my $bsmlFile=<JFILE>){
	    chomp $bsmlFile;
	    $logger->debug("Parsing jaccard file $bsmlFile") if($logger->is_debug());
	    if(-e $bsmlFile){
		$multiparser->parsefile( $bsmlFile );
	    }
	    else{
		$logger->logdie("Can't read jaccard bsml file $bsmlFile");
	    }
	}
	close JFILE;

    }
    else{
	$logger->logdie("Can't read jaccard list $options{'bsmlJaccardList'}");
    }
}


# polypeptide sequence identifer to genome mapping 
my $geneGenomeMap = {};
my $genome = '';

# loop through the documents in the model directory to create the polypeptide genome map
my $genomehandlers = {'Organism'=>
			  sub {
			      my ($expat,$elt,%params) = @_;
			      $genome = $params{'genus'}.':'.$params{'species'}.':'.$params{'strain'};
			  },
		      'Feature'=>
			  sub {
			      my ($expat,$elt,%params) = @_;
			      $logger->debug("Adding $params{'id'} lookup with genome $genome");
			      $geneGenomeMap->{$params{'id'}} = $genome;
			  }
		  };

my $genomeparser = new XML::Parser(Handlers => 
				   {
				       Start =>
					   sub {
					    #$_[1] is the name of the element
					       if(exists $genomehandlers->{$_[1]}){
						   $genomehandlers->{$_[1]}(@_);
					    }
					}
				   }
				   );

foreach my $bsmlFile (@{&get_list_from_file($options{'bsmlModelList'})}){
    
    $logger->debug("Parsing genome file $bsmlFile") if($logger->is_debug());
    $genomeparser->parsefile( $bsmlFile );
    $genome = undef;
}

#####################################

# structure for building the COGS input. For each query gene, the COGS analysis expects
# the single best scoring alignment for each reference genome. In BSML terms, COGS expects the
# highest scoring seqpair for each refseq compseq combination where all compseqs 
# are contained in the same genome. 


#  Genome A           Genome B            Genome C
#  compseqA1          compseqB1           compseqC1
#  compseqA2          compseqB2           compseqC2
#  compseqA3                              compseqC3


# If the above represent the sets of reference genes by genome. The following would 
# correspond to the expected output if A1, B2, and C1 were the best hits by genome. 

# refseq -> compseqA1
# refseq -> compseqB2
# refseq -> compseqC1

####################################
    
my $COGInput = {};

my %alnparams;
my $bestRunScore = 0;
my $isbestrun = 0;
my $bestSeqPairRun = undef;

my $alnhandlers = {'Seq-pair-alignment'=>
		     sub {
			 my ($expat,$elt,%params) = @_;
			 #Process the previous alignment in file
			 &process_alignment($alnparams{'compseq'},$alnparams{'compgenome'},
					    $alnparams{'refseq'},$alnparams{'refgenome'},
					    $bestRunScore,$bestSeqPairRun,
					    $COGInput,$jaccardRepSeqHash,$geneGenomeMap) if(keys %alnparams);

			 my $compseq = $params{'compseq'};
			 my $refseq = $params{'refseq'};
			 my $compGenome = $geneGenomeMap->{$compseq};
			 my $refGenome = $geneGenomeMap->{$refseq};
			 $params{'compgenome'}=$compGenome;
			 $params{'refgenome'}=$compGenome;
			 $bestRunScore = 0;
			 $isbestrun=0;
			 $bestSeqPairRun = undef;
			 %alnparams = ();
			 $logger->debug("Parsing match between $params{'compseq'} $params{'compgenome'} $params{'refseq'} $params{'refgenome'} $isbestrun");


			 # self-self alignments are not included 
			 return if( $compseq eq $refseq );
			 
			 if( !( $compGenome )) 
			 {
			     $logger->debug("$compseq: compseq not found in gene genome map. skipping.") if($logger->is_debug());
			     return;
			 }

			 if( !( $refGenome ) )
			 {
			     $logger->debug("$refseq: compseq not found in gene genome map. skipping.") if($logger->is_debug());
			     return;
			 }
			 
			 # alignments to the same genome are not included in COG clusters
			 
			 return if( $compGenome eq $refGenome );
			 
			 %alnparams = %params;
		     },
		   'Seq-pair-run'=>
		       sub {
			   my ($expat,$elt,%params) = @_;
			   if(keys %alnparams){
			       my $runscore = $params{'runscore'};
			       my $runprob = $params{'runprob'};
			       if( defined $runscore && defined $runprob
				   && ($runscore > $bestRunScore) && ($runprob < $options{'pvalcut'}) ){
				   $logger->debug("$alnparams{'compseq'} $alnparams{'refseq'} using run with runscore $runscore $runprob. Previous bestrunscore $bestRunScore. pvalue cutoff $options{'pvalcut'}");
				   $bestRunScore = $runscore;
				   $logger->debug("bestrunscore $bestRunScore");
				   $bestSeqPairRun->{'reflength'} = $alnparams{'reflength'};
				   $bestSeqPairRun->{'method'} = $alnparams{'method'};
				   $bestSeqPairRun->{'compxref'} = $alnparams{'compxref'};
				   $bestSeqPairRun->{'refpos'} = $params{'refpos'};
				   $bestSeqPairRun->{'runlength'} = $params{'runlength'};
				   $bestSeqPairRun->{'comppos'} = $params{'comppos'};
				   $bestSeqPairRun->{'comprunlength'} = $params{'comprunlength'};
				   $bestSeqPairRun->{'runscore'} = $params{'runscore'};
				   $bestSeqPairRun->{'runprob'} = $runprob;
				   $isbestrun=1;
			       }
			   }
		       },
		   'Attribute'=>
		       sub {
			   my ($expat,$elt,%params) = @_;
			   my $index = scalar(@{$expat->{'Context'}}) - 1;
			   if($isbestrun && $expat->{'Context'}->[$index] eq 'Seq-pair-run'){
			       $logger->debug("Dumping parameters for best run $bestRunScore");
			       if($params{'name'} eq 'p_value'){
				   $bestSeqPairRun->{'p_value'} = $params{'content'};
			       }
			       elsif($params{'name'} eq 'percent_identity'){
				   $bestSeqPairRun->{'percent_identity'} = $params{'content'};
			       }
			       elsif($params{'name'} eq 'percent_similarity'){
				   $bestSeqPairRun->{'percent_similarity'} = $params{'content'};
			       }
			       elsif($params{'name'} eq 'chain_number'){
				   $bestSeqPairRun->{'chain_number'} = $params{'content'};
			       }
			       elsif($params{'name'} eq 'segment_number'){
				   $bestSeqPairRun->{'segment_number'} = $params{'content'};
			       }
			   }
		       }
	       };

my $alnparser = new XML::Parser(Handlers => 
				   {
				       Start =>
					   sub {
					    #$_[1] is the name of the element
					       if(exists $alnhandlers->{$_[1]}){
						   
						   $alnhandlers->{$_[1]}(@_);
					    }
					}
                                }
				);


open( OUTFILE, ">$options{'outfile'}" ) or $logger->logdie("Can't open file $options{'outfile'}");

foreach my $bsmlFile (@{&get_list_from_file($options{'bsmlSearchList'})}){
    
    # builds the COGS input data structure

    $logger->debug("Parsing alignment file $bsmlFile") if($logger->is_debug());
    
    %alnparams = ();
    $bestRunScore = 0;
    $isbestrun = 0;
    $bestSeqPairRun = undef;
    $alnparser->parsefile( $bsmlFile );
    #Process the last alignment in file
    &process_alignment($alnparams{'compseq'},$alnparams{'compgenome'},
		       $alnparams{'refseq'},$alnparams{'refgenome'},
		       $bestRunScore,$bestSeqPairRun,
		       $COGInput,$jaccardRepSeqHash,$geneGenomeMap) if(keys %alnparams);;
    
    # print the results

    foreach my $k1 ( keys( %{$COGInput} ) )
    {
	foreach my $k2 (keys( %{$COGInput->{$k1}}))
	{
	    my $member = $COGInput->{$k1}->{$k2}->[0];
	    if(exists $jaccardClusterHash->{$member}){
		$COGInput->{$k1}->{$k2}->[21] = join(',',@{$jaccardRepSeqHash->{$jaccardClusterHash->{$member}}});
	    }
	    print OUTFILE join("\t", @{$COGInput->{$k1}->{$k2}});
	    print OUTFILE "\n";
	}
    }

    $COGInput = {};
}


sub process_alignment{
    my($compseq,$compGenome,$refseq,$refGenome,$bestRunScore,$bestSeqPairRun,$COGInput,$jaccardRepSeqHash,$geneGenomeMap) = @_;
    # 
    if( ! defined $bestSeqPairRun ){
	$logger->warn("Best run not defined");
	return;
    }
    else{
# If compseq (or refseq) is defined in a Jaccard equivalence class identify the class by
# its reference sequence. 
	
	if( defined( my $jId = $jaccardClusterHash->{$compseq} ) )
	{
	    $logger->debug("Found jaccard cluster $jId for id $compseq. Using $jaccardRepSeqHash->{$jId}->[0] as cluster representative");
	    $compseq = $jaccardRepSeqHash->{$jId}->[0];
	}
	
	if( defined( my $jId = $jaccardClusterHash->{$refseq} ) )
	{
	    $logger->debug("Found jaccard cluster $jId for id $refseq. Using $jaccardRepSeqHash->{$jId}->[0] as cluster representative");
	    $refseq = $jaccardRepSeqHash->{$jId}->[0];
	}
    
	my $lref = [];
	
	$lref->[0] = $refseq;  #query name
	$lref->[1] = '';       #date
	$lref->[2] = $bestSeqPairRun->{ 'reflength' }; #query length
	$lref->[3] = $bestSeqPairRun->{ 'method' }; #program
	$lref->[4] = $bestSeqPairRun->{ 'compxref' };
	$lref->[5] = $compseq;
	$lref->[6] = $bestSeqPairRun->{ 'refpos' };
	$lref->[7] = $bestSeqPairRun->{ 'refpos' } + $bestSeqPairRun->{'runlength'};
	$lref->[8] = $bestSeqPairRun->{ 'comppos' };
	$lref->[9] = $bestSeqPairRun->{ 'comppos' } + $bestSeqPairRun->{'comprunlength'};
	$lref->[10] = $bestSeqPairRun->{'percent_identity'};
	$lref->[11] = $bestSeqPairRun->{'percent_similarity'};
	$lref->[12] = $bestSeqPairRun->{ 'runscore' };
	$lref->[13] = $bestSeqPairRun->{'chain_number'};
	$lref->[14] = $bestSeqPairRun->{'segment_number'};
	$lref->[15] = '';
	$lref->[16] = '';
	$lref->[17] = '';
	$lref->[18] = $bestSeqPairRun->{'comprunlength'};
	$lref->[19] = $bestSeqPairRun->{'runprob' };
	$lref->[20] = $bestSeqPairRun->{'p_value'};
	
	if($refseq && $compseq){
	    if(  $COGInput->{$refseq}->{$compGenome} )
	    {
		if(  $COGInput->{$refseq}->{$compGenome}->[12] < $bestRunScore )
		{
		    $logger->debug("$refseq match to $compGenome with score $bestRunScore is highest scoring match.  Previous high score is $COGInput->{$refseq}->{$compGenome}->[12]");
		    $COGInput->{$refseq}->{$compGenome} = $lref;
		}
	    }
	    else
	    {
		$logger->debug("$refseq match to $compGenome is first match found.");
		$COGInput->{$refseq}->{$compGenome} = $lref;
	    }
	}
    }
}


#########
#clip
########
sub multipleAlignmentHandler
{
    my $aln = shift;
    my $bsml_reader = new BSML::BsmlReader();

    my $maln_ref = $bsml_reader->readMultipleAlignmentTable($aln);

    foreach my $alnSum ( @{ $maln_ref->{'AlignmentSummaries'} } )
    {
	my $seqCount = 0;
	foreach my $alnSeq ( @{ $alnSum->{'AlignedSequences'} } )
	{
	    my $name = $alnSeq->{'name'};
	    $name =~ s/:[\d]*//;

	    # Associate a SeqId with a Jaccard Cluster ID
	    $jaccardClusterHash->{$name} = $jaccardClusterCount;

	    # If this is the first sequence observed in the Jaccard Cluster
	    # identify it as the representative sequence and set it as the 
	    # representative sequence for the Jaccard Cluster ID.
 
	    if( $seqCount == 0 )
	    {
		$jaccardRepSeqHash->{$jaccardClusterCount} = [];
		push @{$jaccardRepSeqHash->{$jaccardClusterCount}},$name;
	    }
	    else{
		push @{$jaccardRepSeqHash->{$jaccardClusterCount}},$name;
	    }
	    $seqCount++;
	}
    }

    $jaccardClusterCount++;
}
sub alignmentHandler
{
    my $aln = shift;
    my $refseq = $aln->returnattr( 'refseq' );
    my $compseq = $aln->returnattr( 'compseq' );

    # if refseq is a CDS identifier, translate it to a polypeptide id. 

    if( my $Trefseq = $cds2Prot->{$refseq} )
    {
	$refseq = $Trefseq;
    }
    
    my $bestRunScore = 0;
    my $bestSeqPairRun = undef;

    # self-self alignments are not included 
    return if( $compseq eq $refseq );

    my $compGenome = $geneGenomeMap->{$compseq};
    my $refGenome = $geneGenomeMap->{$refseq};

    if( !( $compGenome )) 
    {
	$logger->debug("$compseq: compseq not found in gene genome map. skipping.") if($logger->is_debug());
	return;
    }

    if( !( $refGenome ) )
    {
	$logger->debug("$refseq: compseq not found in gene genome map. skipping.") if($logger->is_debug());
	return;
    }

    # alignments to the same genome are not included in COG clusters

    return if( $compGenome eq $refGenome );

     # find the highest scoring run for each pairwise alignment

    foreach my $seqPairRun ( @{$aln->returnBsmlSeqPairRunListR} )
    {
	my $runscore = $seqPairRun->returnattr( 'runscore' );
	my $pvalue = $seqPairRun->{'BsmlAttr'}->{'p_value'}->[0];

	if( ($runscore > $bestRunScore) && ($pvalue < $options{'pvalcut'}) )
	{
	    $logger->debug("Using run with runscore $runscore $pvalue. Previous bestrunscore $bestRunScore. pvalue cutoff $options{'pvalcut'}");
	    $bestRunScore = $runscore;
	    $bestSeqPairRun = $seqPairRun;
	}
    }

    # 
    if( !($bestSeqPairRun) ){
	$logger->warn("Best run not defined");
	return;
    }

    my $runscore = $bestSeqPairRun->returnattr( 'runscore' );
    
    # If compseq (or refseq) is defined in a Jaccard equivalence class identify the class by
    # its reference sequence. 

    if( defined( my $jId = $jaccardClusterHash->{$compseq} ) )
    {
	$logger->debug("Found jaccard cluster $jId for id $compseq. Using $jaccardRepSeqHash->{$jId}->[0] as cluster representative");
	$compseq = $jaccardRepSeqHash->{$jId}->[0];
    }

    if( defined( my $jId = $jaccardClusterHash->{$refseq} ) )
    {
	$logger->debug("Found jaccard cluster $jId for id $refseq. Using $jaccardRepSeqHash->{$jId}->[0] as cluster representative");
	$refseq = $jaccardRepSeqHash->{$jId}->[0];
    }
    
    my $lref = [];
    
    $lref->[0] = $refseq;  #query name
    $lref->[1] = '';       #date
    $lref->[2] = $aln->returnattr( 'reflength' ); #query length
    $lref->[3] = $aln->returnattr( 'method' ); #program
    $lref->[4] = $aln->returnattr( 'compxref' );
    $lref->[5] = $compseq;
    $lref->[6] = $bestSeqPairRun->returnattr( 'refpos' );
    $lref->[7] = $bestSeqPairRun->returnattr( 'refpos' ) + $bestSeqPairRun->returnattr('runlength');
    $lref->[8] = $bestSeqPairRun->returnattr( 'comppos' );
    $lref->[9] = $bestSeqPairRun->returnattr( 'comppos' ) + $bestSeqPairRun->returnattr('comprunlength');
    $lref->[10] = $bestSeqPairRun->{'BsmlAttr'}->{'percent_identity'}->[0];
    $lref->[11] = $bestSeqPairRun->{'BsmlAttr'}->{'percent_similarity'}->[0];
    $lref->[12] = $bestSeqPairRun->returnattr( 'runscore' );
    $lref->[13] = $bestSeqPairRun->{'BsmlAttr'}->{'chain_number'}->[0];
    $lref->[14] = $bestSeqPairRun->{'BsmlAttr'}->{'segment_number'}->[0];
    $lref->[15] = '';
    $lref->[16] = '';
    $lref->[17] = '';
    $lref->[18] = $bestSeqPairRun->returnattr('comprunlength');
    $lref->[19] = $bestSeqPairRun->returnattr('runprob' );
    $lref->[20] = $bestSeqPairRun->{'BsmlAttr'}->{'p_value'}->[0];

   
    if(  $COGInput->{$refseq}->{$compGenome} )
    {
	if(  $COGInput->{$refseq}->{$compGenome}->[12] < $bestRunScore )
	{
	    $logger->debug("$refseq match to $compGenome with score $bestRunScore is highest scoring match.  Previous high score is $COGInput->{$refseq}->{$compGenome}->[12]");
	    $COGInput->{$refseq}->{$compGenome} = $lref;
	}
    }
    else
    {
	$logger->debug("$refseq match to $compGenome is first match found.");
	$COGInput->{$refseq}->{$compGenome} = $lref;
    }
}

sub genomeHandler
{
    my $bsmlGenome = shift;
    my $reader = new BSML::BsmlReader;
    
    my $rhash = $reader->readGenome( $bsmlGenome );

    if( !defined($rhash->{'strain'}) )
    {
	$rhash->{'strain'} = ' ';
    }

    $genome = $rhash->{'genus'}.':'.$rhash->{'species'}.':'.$rhash->{'strain'};
}
	
sub featureHandler
{
    my $feature = shift;
    #
    #the cds class code should be deprecated
    #support for old style legacy2bsml documents only
    if( $feature->returnattr('class') eq 'CDS' )
    {
	my $cdsId = $feature->returnattr('id');
	my $protId = '';
	foreach my $link( @{$feature->returnBsmlLinkListR()} )
	{
	    if( $link->{'rel'} eq 'SEQ' )
	    {
		$protId = $link->{'href'};
		$protId =~ s/#//;

		$logger->debug("Adding polypeptide $protId to polypeptide lookup with genome $genome");
		$logger->debug("Adding CDS $cdsId $protId to cds lookup with protiein $protId");

		$cds2Prot->{$cdsId} = $protId;
		$geneGenomeMap->{$protId} = $genome;

		return;
	    }
	}
    }
    elsif( $feature->returnattr('class') eq 'polypeptide')
    {
	my $protId = $feature->returnattr('id');
	$logger->debug("Adding polypeptide $protId to polypeptide lookup with genome $genome");
	$geneGenomeMap->{$protId} = $genome;
    }
} 

###
#end clip
###

sub get_list_from_file{
    my($file) = @_;
    my @lines;
    open( FH, $file ) or $logger->logdie("Could not open $file");
    while( my $line = <FH> ){
	chomp($line);
	push @lines, split(',',$line) if($line =~ /\S+/);
    }
    return \@lines;
}

sub check_parameters{
    my ($options) = @_;
    
    if(0){
	pod2usage({-exitval => 2,  -message => "error message", -verbose => 1, -output => \*STDERR});    
    }
}

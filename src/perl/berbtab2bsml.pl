#!/usr/bin/perl

=head1  NAME 

berbtab2bsml.pl  - convert info stored in BER btab files into BSML documents 

=head1 SYNOPSIS

USAGE:  berbtab2bsml.pl -b btab_dir -o blastp.bsml -d bsml_dir

=head1 OPTIONS

=over 4

=item *

B<--bsml_dir,-d> [REQUIRED]  Dir containing BSML documents (repository)

=item *

B<--output,-o> [REQUIRED] output BSML file containing bit_score information

=item * 

B<--btab_dir,-b> [REQUIRED] Dir containing btab files

=item *

B<--max_hsp_count> [REQUIRED] Maximum number of HSPs stored per alignment

=item *

B<--gzip_output> [OPTIONAL] A non-zero value will result in compressed bsml output.  A .gz
    extension will be added to the output file name if it doesn't already exist.

=item *

B<--query_file_path,-q> [OPTIONAL] The input fasta file to ber.
    
=item *

B<--class,-c> The ref/comp sequence type.  Default is 'assembly'

=item *

B<--help,-h> This help message

=back

=head1   DESCRIPTION

berbtab2bsml.pl is designed to convert information in ber btab files into BSML documents.

NOTE:  

Calling the script name with NO flags/options or --help will display the syntax requirement.


=cut


use strict;
use Getopt::Long qw(:config no_ignore_case no_auto_abbrev);
use English;
use File::Basename;
use File::Path;
use Pod::Usage;
use Ergatis::Logger;
use BSML::BsmlRepository;
use BSML::BsmlBuilder;
use BSML::BsmlParserTwig;
use Ergatis::IdGenerator;

my %lookupDb;
my %options = ();
my $gzip = 0;
my $results = GetOptions (\%options, 
			  'btab_dir|b=s', 
			  'btab_file|f=s',
			  'bsml_dir|d=s', 
              'mapping_file=s',
			  'output|o=s', 
              'gzip_output=s',
			  'max_hsp_count|m=s',
			  'pvalue|p=s', 
			  'log|l=s',
			  'debug=s',
			  'class|c=s',
			  'analysis_id=s',
              'id_repository=s',
			  'help|h') || pod2usage();

my $logfile = $options{'log'} || Ergatis::Logger::get_default_logfilename();
my $logger = new Ergatis::Logger('LOG_FILE'=>$logfile,
				  'LOG_LEVEL'=>$options{'debug'});
$logger = $logger->get_logger();

if($options{'pvalue'} eq ""){
    $options{'pvalue'} = 10;
}

my $class;
if (!defined($options{'class'})){
    $logger->logdie("class was not defined");
}
else{
    $class = $options{'class'};
}



# display documentation
if( $options{'help'} ){
    pod2usage( {-exitval=>0, -verbose => 2, -output => \*STDOUT} );
}

&check_parameters(\%options);

my $files = &get_btab_files($options{'btab_dir'},$options{'btab_file'});

my $doc = new BSML::BsmlBuilder();
my %featTables;
my $idGenerator;

$doc->makeCurrentDocument();
parse_ber_btabs($files);

$doc->createAndAddAnalysis(
                            id => $options{analysis_id},
                            sourcename => $options{'output'},
                            program => 'ber',
                            algorithm => 'ber',
                          );

$doc->write($options{'output'}, '', $options{'gzip_output'});

sub parse_ber_btabs {

    my $btab_files = shift;
    my $num;
    foreach my $file (@$btab_files) {
	$num++; 
	open (BTAB, "$file") or die "Unable to open \"$file\" due to $!";
	$logger->debug("opening $file $num using pvalue cutoff $options{'pvalue'}") if($logger->is_debug());
	my $query_id;
	while(my $line = <BTAB>) {
	    chomp($line);
	    my @btab = split("\t", $line);

        #if we don't pass the pvalue cutoff
	    next if($btab[20] > $options{'pvalue'} );

        #if it's not created by praze (ber)
	    next if($btab[3] ne 'praze');

	    #next if( !($btab[13] > 0) || !($btab[14] > 0) );

        #make sure we have query id and match id
	    next if(!$btab[0] or !$btab[5]);

	    #$btab[5] =~ s/\|//g;   #get rid of trailing |
	    $query_id = $btab[0];	    
	    my $match_name = $btab[5];

        #&createAndAddFrameshift($btab[19], $btab[0]) if($btab[19]);
	    #splice(@btab, 19, 1);   Why was this happening?
	    
	    for (my $i=0;$i<scalar(@btab);$i++){
            if ($btab[$i] eq 'N/A'){
                $btab[$i] = undef;
            }
	    }
        
	    my $align = &createAndAddBtabLine(
                                          doc                => $doc,
                                          class              => $class,
                                          query_name         => $btab[0],
                                          date               => $btab[1],
                                          query_length       => $btab[2],
                                          blast_program      => $btab[3],
                                          search_database    => $btab[4],
                                          dbmatch_accession  => $btab[5],
                                          start_query        => $btab[6],
                                          stop_query         => $btab[7],
                                          start_hit          => $btab[8],
                                          stop_hit           => $btab[9],
                                          percent_identity   => $btab[10],
                                          percent_similarity => $btab[11],
                                          raw_score          => $btab[12],
                                          bit_score          => $btab[13],
                                          chain_number       => $btab[14],
                                          segment_number     => $btab[14],
                                          dbmatch_header     => $btab[15],
                                          blast_frame        => $btab[16],
                                          query_strand       => $btab[17],
                                          subject_length     => $btab[18],
                                          e_value            => $btab[19],
                                          p_value            => $btab[20]
                                          );

	    my $seq = $doc->returnBsmlSequenceByIDR($match_name);

	}
	close BTAB;
	if ($query_id) {
		my $seq = $doc->returnBsmlSequenceByIDR($query_id);
	}
    }
}

sub get_btab_files{
    my ($directory,$file) = @_;
    my @files;
    if(-d $directory){
	opendir(DIR, $directory) or die "Unable to access $directory due to $!";
	while( my $filename = readdir(DIR)) {
	    if($filename =~ /(.+)\.btab$/) {
		push (@files, "$directory/$filename");
	    }
	}
    }
    if($file ne ""){
	push @files,$file;
    }
    return \@files;
}


sub check_parameters{
    my ($options) = @_;
    
    if(!$options{'output'} or (!$options{'btab_dir'} && !$options{'btab_file'})) {
	pod2usage({-exitval => 2,  -message => "$0: All the required options are not specified", -verbose => 1, -output => \*STDERR});    
    }

    if((! -d $options{'btab_dir'}) && (! -e $options{'btab_file'})) {
	print STDERR "btab directory \"$options{'btab_dir'}\" or btab file $options{'btab_file'} cannot be found.  Aborting...\n";
	exit 5;
    } 

    unless($options{'mapping_file'}) {
        $logger->logdie("mapping_file option is requred.");
    } else {
        $logger->logdie("Mapping_file ($options{mapping_file} does not exist")
            unless(-e $options{'mapping_file'});
        open(IN, "<", $options{'mapping_file'}) or 
            $logger->logdie("Unable to open mapping file $options{mapping_file} ($!)");
        while( my ($prot, $cds, $asm) = split(/\t/, <IN>) ) {
            chomp($asm);
            $lookupDb{$cds} = $asm;
        }

        close(IN);
    }
  
    if($options{'id_repository'}) {
        $logger->logdie("id_repository does not exist") unless(-d $options{'id_repository'});
    } else {
        $logger->logdie("option id_repository is required.");
    }
    $idGenerator = new Ergatis::IdGenerator( 'id_repository' => $options{'id_repository'} );
    $idGenerator->set_pool_size( 'frameshift_mutation' => 25 );

    return 1;
}

sub createAndAddFrameshift {
    my ($fsString,$modelId) = @_;

    my @frameShifts = split(/:/,$fsString);
    $logger->logdie("Could not parse frameshift information from string ($fsString)") unless(@frameShifts);

    $logger->logdie("Model id: ($modelId) does not exist in the lookup_db ($options{lookup_db})") 
        unless(exists($lookupDb{$modelId}));

    my $seqId = $lookupDb{$modelId};
    my $seq;

    #Parse out the project id
    my $project = $1 if($seqId =~ /^([^\.]+)\./);
    
    #Check to see if the sequence has already been added.
    unless( $doc->returnBsmlSequenceByIDR( $seqId ) ){
	    $seq = $doc->createAndAddSequence( $seqId, $seqId, '', 'na', 'assembly' );
		$seq->addBsmlLink('analysis', '#' . $options{analysis_id}, 'input_of');
    }

    #Check to see if said sequence object has a feature table object
    unless(exists($featTables{$seqId})) {
        $featTables{$seqId} = $doc->createAndAddFeatureTable($seq);
    }

    #Now add the frameshifts
    foreach my $fs (@frameShifts) {
        my ($start, $end) = ($1, $2) if($fs =~ /(.+)-(.+)/);
        $logger->logdie("Could not parse frameshift data ($fs)")
            unless($start && $end);

        ($start--, $end--);
        my $strand = 0;
        
        if($start > $end) {
            ($end, $start) = ($start, $end);
            $strand = 1;
        }
        
        my $fId = $idGenerator->next_id('type' => 'frameshift_mutation', 'project' => $project);
        my $feat = $doc->createAndAddFeature($featTables{$seqId}, $fId, $fId, 'frameshift_mutation');

        $feat->addBsmlLink('analysis', '#'.$options{'analysis_id'}, 'computed_by');
        $feat->addBsmlIntervalLoc($start, $end, $strand);

       
        
    }
    
}

sub createAndAddBtabLine {

    my %args = @_;
    my $doc = $args{'doc'};
    
    my $nice_id = $args{'dbmatch_accession'};
    $nice_id =~ s/\|/_/g;

    #determine if the query name and the dbmatch name are a unique pair in the document
    
    my $alignment_pair_list = BSML::BsmlDoc::BsmlReturnAlignmentLookup( "$args{'query_name'}", "$nice_id" );

    my $alignment_pair = '';
    if( $alignment_pair_list )
    {
	$alignment_pair = $alignment_pair_list->[0];
    }

    if( $alignment_pair  )
	  {
	    #add a new BsmlSeqPairRun to the alignment pair and return
	    my $seq_run = $alignment_pair->returnBsmlSeqPairRunR( $alignment_pair->addBsmlSeqPairRun() );

	    if( $args{'start_query'} > $args{'stop_query'} )
	      {
		$seq_run->setattr( 'refpos', $args{'stop_query'}-1 );
		$seq_run->setattr( 'runlength', $args{'start_query'} - $args{'stop_query'} + 1 );
		$seq_run->setattr( 'refcomplement', 1 );
	      }
	    else
	      {
		$seq_run->setattr( 'refpos', $args{'start_query'}-1 );
		$seq_run->setattr( 'runlength', $args{'stop_query'} - $args{'start_query'} + 1 );
		$seq_run->setattr( 'refcomplement', 0 );
	      }

	    #the database sequence is always 5' to 3'

	    $seq_run->setattr( 'comppos', $args{'start_hit'} -1 )                                   if (defined ($args{'start_hit'}));
	    $seq_run->setattr( 'comprunlength', $args{'stop_hit'} - $args{'start_hit'} + 1 )     if ((defined ($args{'start_hit'})) and (defined ($args{'stop_hit'})));
	    $seq_run->setattr( 'compcomplement', 0 );

	    $seq_run->setattr( 'runscore', $args{'bit_score'} )                                  if (defined ($args{'bit_score'}));
	    $seq_run->setattr( 'runprob', $args{'e_value'} )                                     if (defined ($args{'e_value'}));

        $seq_run->addBsmlAttr( 'class', 'match_part' );
	    $seq_run->addBsmlAttr( 'percent_identity', $args{'percent_identity'} )               if (defined ($args{'percent_identity'}));   
	    $seq_run->addBsmlAttr( 'percent_similarity', $args{'percent_similarity'} )           if (defined ($args{'percent_similarity'}));
	    $seq_run->addBsmlAttr( 'chain_number', $args{'chain_number'} )                       if (defined ($args{'chain_number'}));
	    $seq_run->addBsmlAttr( 'segment_number', $args{'segment_number'} )                   if (defined ($args{'segment_number'}));
	    $seq_run->addBsmlAttr( 'p_value', $args{'p_value'} )                                 if (defined ($args{'p_value'}));

	    return $alignment_pair;
	  }

    #no alignment pair matches, add a new alignment pair and sequence run
    #check to see if sequences exist in the BsmlDoc, if not add them with basic attributes
    my $seq;
    
    if( !( $doc->returnBsmlSequenceByIDR( "$args{'query_name'}")) ){
	    $seq = $doc->createAndAddSequence( "$args{'query_name'}", "$args{'query_name'}", $args{'query_length'}, 'dna', $args{'class'} );
		$seq->addBsmlLink('analysis', '#' . $options{analysis_id}, 'input_of');
    }

    
    if( !( $doc->returnBsmlSequenceByIDR( "$args{'dbmatch_accession'}")) ){
        $seq = $doc->createAndAddSequence( "$nice_id", "$args{'dbmatch_header'}", $args{'subject_length'}, 'aa', 'polypeptide' );
        $doc->createAndAddBsmlAttribute( $seq, 'defline', $args{'dbmatch_accession'} );
    }

    ## see if the dbmatch_header format is recognized.  if so, add some cross-references
    if (defined $args{'dbmatch_header'}) {
        $doc->createAndAddCrossReferencesByParse( sequence => $seq, string => $args{'dbmatch_header'} );
    }

    $alignment_pair = $doc->returnBsmlSeqPairAlignmentR( $doc->addBsmlSeqPairAlignment() );

	## add analysis link 
	$alignment_pair->addBsmlLink('analysis', '#' . $options{analysis_id}, 'computed_by');

    $alignment_pair->setattr( 'refseq', "$args{'query_name'}" )                                 if (defined ($args{'query_name'}));
    $alignment_pair->setattr( 'compseq', "$nice_id" )                         if (defined ($args{'dbmatch_accession'}));
    
    BSML::BsmlDoc::BsmlSetAlignmentLookup( "$args{'query_name'}", "$nice_id", $alignment_pair );

    $alignment_pair->setattr( 'refxref', ':'.$args{'query_name'})        if (defined ($args{'query_name'}));                     
    $alignment_pair->setattr( 'refstart', 0 );
    $alignment_pair->setattr( 'refend', $args{'query_length'} )      if (defined ($args{'query_length'}));
    $alignment_pair->setattr( 'reflength', $args{'query_length'} )       if (defined ($args{'query_length'}));

    $alignment_pair->setattr( 'method', $args{'blast_program'} )         if (defined ($args{'blast_program'}));

    $alignment_pair->setattr( 'compxref', $args{'search_database'}.':'.$args{'dbmatch_accession'} )  if ((defined ($args{'search_database'})) and (defined ($args{'dbmatch_accession'})));
    $alignment_pair->setattr( 'class', 'match' );

    my $seq_run = $alignment_pair->returnBsmlSeqPairRunR( $alignment_pair->addBsmlSeqPairRun() );

    if( $args{'start_query'} > $args{'stop_query'} )
      {
	$seq_run->setattr( 'refpos', $args{'stop_query'}-1 );
	$seq_run->setattr( 'runlength', $args{'start_query'} - $args{'stop_query'} + 1 );
	$seq_run->setattr( 'refcomplement', 1 );
      }
    else
      {
	$seq_run->setattr( 'refpos', $args{'start_query'} -1);
	$seq_run->setattr( 'runlength', $args{'stop_query'} - $args{'start_query'} + 1 );
	$seq_run->setattr( 'refcomplement', 0 );
      }

    #the database sequence is always 5' to 3'
    
    $seq_run->setattr( 'comppos', $args{'start_hit'} -1)                                     if (defined  ($args{'start_hit'}));
    $seq_run->setattr( 'comprunlength', ($args{'stop_hit'} - $args{'start_hit'} + 1))      if ((defined ($args{'start_hit'})) and (defined ($args{'stop_hit'})));
    $seq_run->setattr( 'compcomplement', 0 );
    
    $seq_run->setattr( 'runscore', $args{'bit_score'} )                                    if (defined  ($args{'bit_score'}));
    $seq_run->setattr( 'runprob', $args{'e_value'} )                                       if (defined  ($args{'e_value'}));

    $seq_run->addBsmlAttr( 'class', 'match_part');
    $seq_run->addBsmlAttr( 'percent_identity', $args{'percent_identity'} )                 if (defined  ($args{'percent_identity'}));
    $seq_run->addBsmlAttr( 'percent_similarity', $args{'percent_similarity'} )             if (defined  ($args{'percent_similarity'}));
    $seq_run->addBsmlAttr( 'chain_number', $args{'chain_number'} )                         if (defined  ($args{'chain_number'}));
    $seq_run->addBsmlAttr( 'segment_number', $args{'segment_number'} )                     if (defined  ($args{'segment_number'}));
    $seq_run->addBsmlAttr( 'p_value', $args{'p_value'} )                                   if (defined  ($args{'p_value'}));

    return $alignment_pair;


}

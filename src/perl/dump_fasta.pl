#!/usr/bin/env perl

=head1 NAME

dump_fasta.pl - Dump the contents of an IGS MySQL Chado annotation database into .fsa files that can be processed by NCBI's tbl2asn utility.

=head1 SYNOPSIS

 USAGE: dump_fasta.pl
       --database_list=/path/to/database.list
       --username=db_user1
       --password=db_password1
       --server=annot_db.someplace.org
     [ --linker_sequence=NNNNNCACACACTTAATTAATTAAGTGTGTGNNNNN
       --contig_string='contig'
       --contig_id_replacement='_contigs\.ctg/.ctg'
       --output_dir=TIGR_moore
       --log=/path/to/file.log
       --help
       --test
     ]

=head1 OPTIONS

B<--database_list,-d>
    The path to a list file with newline-seperated names of chado-compliant annotation databases that reside on the MySQL database server specified by --server.
    If a comma (,) is added after the database name, then the user can specify a database_abbreviation.  This is essentially a shorter version of the database name that is used to generate contig ids.
    If the generated contig ids are too long then they will clash with the sequence length in the LOCUS line of the GenBank flat file generated by tbl2asn.

B<--username,-u>
    The MySQL username of a user with SELECT permissions on --database.

B<--password,-p>
    The MySQL password for the username specified by --username on the MySQL server --server.

B<--server,-s>
    The MySQL server on which the database specified by the --database option resides.

B<--linker_sequence,-k>
    Optional.  Sequence on which to split sequences into contigs.  Set to the IGS "pmark" sequence
    (NNNNNCACACACTTAATTAATTAAGTGTGTGNNNNN) by default.

B<--contig_string,-n>
    Optional.  String to use in constructing contig ids.  Default is "contig".  e.g., dbname.contig.0,
    dbname.contig.1, dbname.contig.2, etc.

B<--contig_id_replacement,-r>
    Optional.  Perl-style substitution to apply to contig ids.  This can be used to ensure that dump_table.pl
    does not produce contig ids that are too long for tbl2asn to output to GenBank format, for example by
    setting the replacement to '_contigs\.ctg/.ctg' in order to remove "_contigs" from each contig
    name.  Note that the replacement string must contain exactly one "/" character to separate the string
    being replaced from the replacement string.

B<--output_dir,-o>
    Optional.  Directory into which to write the target .fsa and .tbl files.  Default is to use
    the current working directory.  Each database in the list will have a directory created
    within this output directory

B<--log,-l>
    Optional.  Location of a log file to which error messages/warnings should be written.

B<--help,-h>
    Optional.  Print this documentation.

B<--test,-t>
    Optional.  Tests the contig-splitting code on synthetic data.

=head1  DESCRIPTION

Dumps the contents of an IGS MySQL Chado annotation database into .fsa
files that can be processed by NCBI's tbl2asn utility.  The
sequences read from the database will be split into contigs using the
specified linker sequence (--linker_sequence) and any contigs that are
composed entirely of Ns (or are empty) will be discarded and will not
be included in the output.

This is actually a stripped-down version of dump_table.pl, which also outputs .tbl files

=head1 INPUT

A MySQL Chado annotation database list.

database1
database2,db2

In this case, database2 will have the contigs renamed to the abbreviation, db2.

=head1 OUTPUT

Generates two files in the directory specified by --output_dir:

1. database.fsa - multi-FASTA file of contig sequences

=head1  CONTACT

    Shaun Adkins
    sadkins@som.umaryland.edu

=cut

use strict;
use warnings;
use Getopt::Long qw(:config no_ignore_case no_auto_abbrev pass_through);
use Pod::Usage;
use Data::Dumper;
use DBI;

############# GLOBALS AND CONSTANTS ################
my $DEBUG_LEVEL = 1;
my ($ERROR, $WARN, $DEBUG) = (1,2,3);
my $DEFAULT_LOCUS_DB = "TIGR_moore";
my $DEFAULT_LINKER_SEQUENCE = "NNNNNCACACACTTAATTAATTAAGTGTGTGNNNNN";
my $DEFAULT_OUTPUT_DIR = ".";
my $DEFAULT_CONTIG_STRING = "ctg";

my $LOGFH;
my %QUERIES = ();
my $DBH;
my $CONTIG_NUMBER = 0;
my $FSAFH;
my $LINKER;
my $OUTPUT_DIR;
my $CONTIG_STRING;
my %db = ();
my $contigs;
my $db_abbr;
####################################################

my %options;
my $results = GetOptions (\%options,
                          "database_list|d=s",
                          "username|u=s",
                          "password|p=s",
                          "server|s=s",
                          "linker_sequence|k=s",
                          "contig_string|n=s",
                          "contig_id_replacement|r=s",
                          "output_dir|o=s",
                          "log|l=s",
                          "help|h",
                          "test|t",
                          );

&check_options(\%options);
%db = &parse_db_list(\%options);

foreach my $database (keys %db){
    print "Now preparing to dump $database...\n";
    &init(\%options, $database);
    &prepare_queries( \%QUERIES);  # prepare SQL commands to issue to the Chado database

    ## grab the assemblies
    $QUERIES{'get_assembly'}->execute();
    # get_assembly returns list of [feature uniquename, sequence, feature id]
    while( my $row = $QUERIES{'get_assembly'}->fetchrow_arrayref() ) {
	    $contigs = &make_contigs( $LINKER, $row->[1], $database, $row->[0]);

        ## now print the genes
        foreach my $c ( @{$contigs} ) {
            my $clength = length( $c->{'sequence'} );
            my $cid = $c->{'id'};
            # apply --contig_id_replacement, if defined
            if (defined($options{'contig_id_replacement'})) {
                my($replace, $with) = split(/\//, $options{'contig_id_replacement'});
                $cid =~ s/$replace/$with/;
            }

            ## print the sequence
            print $FSAFH ">$cid\n";
            while( $c->{'sequence'} =~ /(\w{1,60})/g ) {
                print $FSAFH "$1\n";
            }
        }
    }
    close($FSAFH);
    $DBH->disconnect();	# Disconnect current database so next database can be connected w/o warnings
}
exit(0);

sub make_contigs {
    my ($linker, $sequence, $database, $assembly) = @_;
    my $linker_len = length($linker);
    my $contigs = [];
    my $contig = { 'start' => 0, 'end' => undef };

    # $ls, $le - linker coordinates
    my $add_contig = sub {
      my($ls,$le) = @_;
      # note that contig 'start' and 'end' are actually chado-style fmin/fmax coordinates
      $contig->{'end'} = $ls;
      my $clen = $contig->{'end'} - $contig->{'start'};
      my $cseq = $contig->{'sequence'} = substr($sequence, $contig->{'start'}, $clen);
      # skip contigs that are empty or all Ns
      if ($cseq !~ /^N*$/i) {
        if (defined $db{$database}) {
            $contig->{'id'} = $db{$database} . "." . $CONTIG_STRING . ".".$CONTIG_NUMBER++;
        } else {
            $contig->{'id'} = $database . "." . $CONTIG_STRING . "." . $CONTIG_NUMBER++;
        }
        push(@$contigs, $contig);
      }
      # reset for next contig
      $contig = { 'start' => $le, 'end' => undef };
    };

    my $positions = [];
    while ($sequence =~ /$linker/gi) {
      my $l_end = pos($sequence);
      my $l_start = $l_end - $linker_len;
      push(@$positions, [$l_start, $l_end]);
    }

    push(@$positions, [length($sequence), undef]);
    map { &$add_contig(@$_); } @$positions;
    return $contigs;
}

sub prepare_queries {
    my ($queries) = @_;

    my $q = "SELECT f.uniquename, f.residues, f.feature_id ".
        "FROM feature f, cvterm c ".
        "WHERE c.name = 'assembly' AND c.cvterm_id = f.type_id";
    $queries->{'get_assembly'} = $DBH->prepare($q);
}

sub check_options {
   my $opts = shift;

   if( $opts->{'help'} ) {
       &_pod;
   }

   if( $opts->{'test'} ) {
       &_test;
   }

   if( $opts->{'log'} ) {
       open( $LOGFH, "> $opts->{'log'}") or die("Can't open log file ($!)");
   }

   foreach my $req ( qw(username password database_list server) ) {
       &_log($ERROR, "Option $req is required") unless( $opts->{$req} );
   }

   # set default values
   $LINKER = $opts->{'linker_sequence'} ? $opts->{'linker_sequence'} : $DEFAULT_LINKER_SEQUENCE;
   $OUTPUT_DIR = $opts->{'output_dir'} ? $opts->{'output_dir'} : $DEFAULT_OUTPUT_DIR;
   unless (-d $OUTPUT_DIR) { mkdir $OUTPUT_DIR;}	#Make output directory if it doesn't exist
   $CONTIG_STRING = $opts->{'contig_string'} ? $opts->{'contig_string'} : $DEFAULT_CONTIG_STRING;
}

sub parse_db_list {
    my ($opts) = @_;
    my %database;
    open LIST, $opts->{'database_list'} or die ("Cannot open database list for reading: $!\n");
    while (<LIST>) {
        chomp;
        my $line = $_;
        my ($db, $abbr, $rest)= split(/,|\t/, $line, 3);	#split into db and abbr
        $db =~ s/^\s+//;	#Strip off spaces before both (space before abbr would be reflected in contig header)
        #print $parts[0], "\t", $parts[1], "\n";
        next if ($db eq "");	#safety check against a line starting with a comma
        if (defined $abbr && length($abbr)) {	# If there is a database_abbreviation present, then assign it to the database key
            $abbr =~ s/^\s+//;
            $database{$db} = $abbr;
        } else {
             $database{$db} = undef;
        }
    }
    close LIST;

    return %database;
}

sub init {
  my($opts, $db) = @_;
  unless (-d $OUTPUT_DIR . "/$db") { mkdir $OUTPUT_DIR . "/$db";}	#Make output directory if it doesn't exist
  my $dir = $OUTPUT_DIR . "/$db";
  &_connect( $opts->{'username'}, $opts->{'password'}, $db, $opts->{'server'} );
  my $f = $dir . "/$db.fsa";
  open($FSAFH, ">$f") or die("can't open $f for writing:$!");
}

sub _connect {
  my ($user, $password, $db, $server) = @_;
  eval {
  $DBH = DBI->connect("DBI:mysql:$db:$server", "$user", "$password",
                       {
                                'RaiseError' => 1,
                                'AutoCommit' => 0,
                          } );
    };
    if( $@ ) {
        die("Could not connect to database ".DBI->errstr);
    }
    $DBH->do("use $db");
}

sub _log {
   my ($level, $msg) = @_;
   if( $level <= $DEBUG_LEVEL ) {
      print STDOUT "$msg\n";
   }
   print $LOGFH "$msg\n" if( defined( $LOGFH ) );
   exit(1) if( $level == $ERROR );
}

sub _pod {
    pod2usage( {-exitval => 0, -verbose => 2, -output => \*STDERR} );
}

# do some testing
sub _test {
  my $TEST_CONTIGS =
    [
     { 'descr' => "actg, 2 pmarks, tttt", 'contigs' => ['ACTG', '', 'TTTT'] },
     { 'descr' => "actg, pmark, nnnnn, pmark, tttt", 'contigs' => ['ACTG', 'NNNNN', 'TTTT'] },
     { 'descr' => "actg, pmark, aaaan, pmark, tttt", 'contigs' => ['ACTG', 'AAAAN', 'TTTT'] },
     { 'descr' => "nnnn, pmark, actgt, pmark, tttt", 'contigs' => ['NNNN', 'ACTGT', 'TTTT'] },
     { 'descr' => "tttt, pmark, actgt, pmark, nnnn", 'contigs' => ['TTTT', 'ACTGT', 'NNNN'] },
     { 'descr' => "nnnn, pmark, actgt, pmark, nnnn", 'contigs' => ['NNNN', 'ACTGT', 'NNNN'] },
     { 'descr' => "nnnn, pmark, nnnn, pmark, nnnn", 'contigs' => ['NNNN', 'NNNN', 'NNNN'] },
    ];

  my $num_tests = 0;
  my $num_ok = 0;
  my $num_failed = 0;

  $options{'database_abbreviation'} = $options{'database'} = 'test';
  $LINKER = $DEFAULT_LINKER_SEQUENCE;
  $CONTIG_STRING = $DEFAULT_CONTIG_STRING;

  foreach my $tc (@$TEST_CONTIGS) {
      my $seq = join($LINKER, @{$tc->{'contigs'}});

      # test on both uppercase and lowercase sequence
      foreach my $cseq (uc($seq), lc($seq)) {
        ++$num_tests;

        my $c2 = &make_contigs($LINKER, $cseq);
        my $c2s = sub {
          my $c = shift;
          return "[id:" . $c->{'id'} . " coords:" . $c->{'start'} . "-" . $c->{'end'} . " seq:" .  $c->{'sequence'} . "]";
        };

        print "           descr = " . $tc->{'descr'} . "\n";
        print "         contigs = " . join(',', @{$tc->{'contigs'}}) . "\n";
        print "             seq = " . $cseq. " (length=" . length($cseq) . ")\n";
        print "         contigs = \n" . join("\n", map {"  " . &$c2s($_)} @$c2) . "\n";

        # check whether the test was successful
        my $actual_result = join("|", map {$_->{'sequence'}} @$c2);
        my $expected_result = join("|", grep(/[^n]+/i,  @{$tc->{'contigs'}}));

        if (uc($actual_result) eq uc($expected_result)) {
          ++$num_ok;
          print "          result = SUCCESS\n";
        } else {
          ++$num_failed;
          print "          result = FAILED (actual=$actual_result, expected=$expected_result)\n";
        }
        print "\n";
      }
    }

  # check result and return appropriate exit code
  print "\n";
  print "$num_ok/$num_tests passed ok, $num_failed failed\n";

  my $exitval = ($num_failed == 0) ? 0 : 1;
  exit($exitval);
}

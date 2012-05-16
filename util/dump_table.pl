#!/usr/bin/env perl

=head1 NAME

dump_table.pl - Dump the contents of an IGS MySQL Chado annotation database into .fsa and .tbl files that can be processed by NCBI's tbl2asn utility.

=head1 SYNOPSIS

 USAGE: dump_table.pl
       --database=annot_db_A
       --username=db_user1
       --password=db_password1
       --server=annot_db.someplace.org
     [ --linker_sequence=NNNNNCACACACTTAATTAATTAAGTGTGTGNNNNN
       --contig_string='contig'
       --contig_id_replacement='_contigs\.ctg/.ctg'
       --database_abbreviation=annot_db_A
       --locus_db=TIGR_moore
       --output_dir=TIGR_moore
       --log=/path/to/file.log
       --help
       --test
     ]

=head1 OPTIONS

B<--database,-d>
    The name of a chado-compliant annotation database that resides on the MySQL database server specified by --server.

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

B<--database_abbreviation,-a>
    Optional.  A shorter version of --database that is used to generate contig ids.  If the generated contig
    ids are too long then they will clash with the sequence length in the LOCUS line of the GenBank flat
    file generated by tbl2asn.

B<--mapping_list -m>
    Optional.  Allows the user to detect pmarks using a fuzznuc mapping file rather than the linker sequence

B<--locus_db,-c>
    Optional.  Chado db.name to use when querying for dbxrefs to output in NCBI/GenBank "locus_tag" 
    field.  Set to "TIGR_moore" by default.

B<--output_dir,-o>
    Optional.  Directory into which to write the target .fsa and .tbl files.  Default is to use
    the current working directory.

B<--log,-l>
    Optional.  Location of a log file to which error messages/warnings should be written.

B<--help,-h>
    Optional.  Print this documentation.

B<--test,-t>
    Optional.  Tests the contig-splitting code on synthetic data.

=head1  DESCRIPTION

Dumps the contents of an IGS MySQL Chado annotation database into .fsa
and .tbl files that can be processed by NCBI's tbl2asn utility.  The
sequences read from the database will be split into contigs using the
specified linker sequence (--linker_sequence) and any contigs that are
composed entirely of Ns (or are empty) will be discarded and will not
be included in the output.  

=head1 INPUT

A MySQL Chado annotation database.

=head1 OUTPUT

Generates two files in the directory specified by --output_dir:

1. database.fsa - multi-FASTA file of contig sequences
2. database.tbl - tbl2asn-compatible feature table file

=head1  CONTACT

    Kevin Galens
    kgalens@gmail.com

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
my $DEFAULT_CONTIG_STRING = "contig";

my $LOGFH;
my %QUERIES = ();
my $DBH;
my $LOCUS_DB;
my $CONTIG_NUMBER = 0;
my $OFH;
my $FSAFH;
my $LINKER;
my $OUTPUT_DIR;
my $CONTIG_STRING;
my $fuzznuc_flag = 0;	# Will be enabled if the user enters a fuzznuc mapping file
my %mapping_files = ();
my $contigs;
####################################################

my %options;
my $results = GetOptions (\%options,
                          "database|d=s",
                          "username|u=s",
                          "password|p=s",
                          "server|s=s",
                          "linker_sequence|k=s",
                          "contig_string|n=s",
                          "contig_id_replacement|r=s",
                          "database_abbreviation|a=s",
			  "mapping_list|m=s",
                          "locus_db|c=s",
                          "output_dir|o=s",
                          "log|l=s",
                          "help|h",
                          "test|t",
                          );

&check_options(\%options);
&init(\%options);
&prepare_queries( \%QUERIES );  # prepare SQL commands to issue to the Chado database

## grab the assemblies
$QUERIES{'get_assembly'}->execute();
# get_assembly returns list of [feature uniquename, sequence, feature id]
while( my $row = $QUERIES{'get_assembly'}->fetchrow_arrayref() ) { 
    ## make contigs
    if ($fuzznuc_flag) {
	#print "Using fuzznuc search mapping list...\n";
	next unless( exists( $mapping_files{$row->[0]} ) );
	$contigs = &make_contigs_via_map($mapping_files{$row->[0]}, $row->[1]);
    } else {
	$contigs = &make_contigs( $LINKER, $row->[1] );
    }

    ## grab gene sequences
    $QUERIES{'get_transcripts'}->execute($row->[2]);    #execute based on feature_id of "get_assembly"

    while( my $gene_row = $QUERIES{'get_transcripts'}->fetchrow_arrayref() ) {
        foreach my $c ( @{$contigs} ) {
            if( $gene_row->[2] <= $c->{'end'} && $gene_row->[2] >= $c->{'start'} ) {
                $c->{'genes'} = [] unless( exists( $c->{'genes'} ) );

                ## grab the common name
                $QUERIES{'get_gpn'}->execute( $gene_row->[0] );
                my $r = $QUERIES{'get_gpn'}->fetchall_arrayref();
                my $gpn = $r->[0]->[0];
                unless( $gpn ) {
                    $QUERIES{'get_name'}->execute( $gene_row->[0] );
                    $r = $QUERIES{'get_name'}->fetchall_arrayref();
                    $gpn = $r->[0]->[0];
                }
                die("Could not parse gpn for $gene_row->[0]") unless( $gpn );

                my $tmp = {
                    'feature_id' => $gene_row->[0],
                    'fmin' => $gene_row->[2] - $c->{'start'},
                    'fmax' => $gene_row->[3] - $c->{'start'},
                    'strand' => $gene_row->[4],
                    'type' => $gene_row->[5],
                    'gpn' => $gpn
                };
                if( $tmp->{'fmin'} < 0 and $tmp->{'fmax'} < 0 ) {
                    print Dumper( $gene_row );
                    print Dumper( $tmp );
                    exit(1);
                }
                push( @{$c->{'genes'}}, $tmp );
                last;
              }
            if( $gene_row->[2] < $c->{'start'} ) {
                ## grab the common name
                $QUERIES{'get_gpn'}->execute( $gene_row->[0] );
                my $r = $QUERIES{'get_gpn'}->fetchall_arrayref();
                my $gpn = $r->[0]->[0];
                unless( $gpn ) {
                    $QUERIES{'get_name'}->execute( $gene_row->[0] );
                    $r = $QUERIES{'get_name'}->fetchall_arrayref();
                    $gpn = $r->[0]->[0];
                }
                die("Could not parse gpn for $gene_row->[0]") unless( $gpn );

                my $tmp = {
                    'feature_id' => $gene_row->[0],
                    'fmin' => $gene_row->[2] - $c->{'start'},
                    'fmax' => $gene_row->[3] - $c->{'start'},
                    'strand' => $gene_row->[4],
                    'type' => $gene_row->[5],
                    'gpn' => $gpn
                    };

                if( $tmp->{'fmin'} < 0 and $tmp->{'fmax'} < 0 ) {
                    print Dumper( $gene_row );
                    print Dumper( $tmp );
                    exit(1);
                }
                push( @{$c->{'genes'}}, $tmp );
                last;
            }
        }
    }

    ## now print the genes
    foreach my $c ( @{$contigs} ) {
        my $clength = length( $c->{'sequence'} );
        my $cid = $c->{'id'};
        # apply --contig_id_replacement, if defined
        if (defined($options{'contig_id_replacement'})) {
          my($replace, $with) = split(/\//, $options{'contig_id_replacement'});
          $cid =~ s/$replace/$with/;
        }
        print $OFH ">Feature $cid\n";
        foreach my $g ( @{$c->{'genes'}} ) {
            add_feature( $OFH, $g, $g->{'type'}, $clength )
        }

        ## print the sequence
        print $FSAFH ">$cid\n";
        while( $c->{'sequence'} =~ /(\w{1,60})/g ) {
            print $FSAFH "$1\n";
        }
    }
}
close($OFH);
close($FSAFH);
exit(0);

sub add_feature {
    my ($ofh, $g, $feature_type, $clength) = @_;
    my ($s, $e) = ($g->{'strand'} > 0) ? ($g->{'fmin'}+1,$g->{'fmax'}) : ($g->{'fmax'}, $g->{'fmin'}+1);    #determine start and end sites 

    my $codon_start;
    if( $s < 1 ) {
        $s = "<1";
        my $m = $e%3;
        if( $m == 1 ) {
            $codon_start = 2;
        } elsif( $m == 2 ) {
            $codon_start = 3;
        } elsif( $m == 0 ) {
            $codon_start = 1;
        }
    } elsif( $s > $clength ) {
        $s = "<$clength";
        my $delta = ($clength - $e) + 1;
        my $m = $delta%3;
        if( $m == 1 ) {
            $codon_start = 2;
        } elsif( $m == 2 ) {
            $codon_start = 3;
        } elsif( $m == 0 ) {
            $codon_start = 1;
        }
    }
    
    if( $e < 1 ) {
        $e = ">1";
    } elsif( $e > $clength ) {
        $e = ">$clength";
    }

    # sanity check: GenBank spec. does not allow coordinates below 1
    my($snum) = ($s =~ /(\d+)/);
    my($enum) = ($e =~ /(\d+)/);
    die "illegal coordinates s=$s, e=$e" if (($snum <= 0) || ($enum <= 0));
    
    # print output of .tbl file
    if( $g->{'gpn'} =~ /(unverified frameshift|unverified point mutation|degenerate)/ ) {

	# make note that gene has problems so that it does not produce the expected translation 
	my $note;	
        ($note = $g->{'gpn'}) =~ s/(unverified frameshift|unverified point mutation|degenerate)/non-functional due to frameshift/;

        print $ofh $s."\t".$e."\tgene\n";
        $QUERIES{'get_locus'}->execute( $g->{'feature_id'} );
        my $r = $QUERIES{'get_locus'}->fetchall_arrayref();
        my $locus = $r->[0]->[0];
        die("Can't find locus for $g->{'feature_id'}") unless( $locus );
        print $ofh "\t\t\tlocus_tag\t$locus\n";
        print $ofh "\t\t\tnote\t$note\n";
        
    } else {

        print $ofh $s."\t".$e."\tgene\n";

        $QUERIES{'get_locus'}->execute( $g->{'feature_id'} );
        my $r = $QUERIES{'get_locus'}->fetchall_arrayref();
        my $locus = $r->[0]->[0];
        die("Can't find locus for $g->{'feature_id'}") unless( $locus );
        print $ofh "\t\t\tlocus_tag\t$locus\n";

        ##grab gene symbol
        $QUERIES{'get_gene_symbol'}->execute( $g->{'feature_id'} );
        $r = $QUERIES{'get_gene_symbol'}->fetchall_arrayref();
        my $gs = $r->[0]->[0];
        print $ofh "\t\t\tgene\t$gs\n" if( defined( $gs ) && ( $gs =~ /\S/ ));

        ## grab ec
        $QUERIES{'get_ec'}->execute( $g->{'feature_id'} );
        $r = $QUERIES{'get_ec'}->fetchall_arrayref();
        my $ec = $r->[0]->[0];
        
        $feature_type = 'CDS' if( $feature_type eq 'transcript' );
        print $ofh $s."\t".$e."\t$feature_type\n";
        print $ofh "\t\t\tproduct\t$g->{'gpn'}\n";
        print $ofh "\t\t\tEC_number\t$ec\n" if( $ec );
        print $ofh "\t\t\tcodon_start\t$codon_start\n" if( defined( $codon_start ) );
        print $ofh "\t\t\tprotein_id\tgnl|IGS|$locus\n";
    }
}
sub make_contigs_via_map {
    my ($map, $sequence) = @_;
    my $positions = [];
    my $contigs = [];
    my ($start, $end) = (-1, -1); # dummy values to reset to

    open(IN, "< $map") or die("Can't open file $map: $!");

    my $contig = { 'start' => 0, 'end' => undef };

    # $ls, $le - linker coordinates
    my $add_contig = sub {
      my($ls,$le) = @_;
      # note that contig 'start' and 'end' are actually chado-style fmin/fmax coordinates
      $contig->{'end'} = $ls;
      my $clen = $contig->{'end'} - $contig->{'start'};
      my $cseq = $contig->{'sequence'} = substr($sequence, $contig->{'start'}, $clen);
print "START: $contig->{'start'}\tEND: $contig->{'end'}\tNUMBER: $CONTIG_NUMBER\n";
      # skip contigs that are empty or all Ns
      if ($cseq !~ /^N*$/i) {
        $contig->{'id'} = $options{'database_abbreviation'}."." . $CONTIG_STRING . ".".$CONTIG_NUMBER++;
        push(@$contigs, $contig);
      }
      # reset for next contig
      $contig = { 'start' => $le, 'end' => undef };
    };

    while(<IN>) {
        if( /Start: (\d+)/ ) {
            $start = $1;
        } elsif( /End: (\d+)/ ) {
            $end = $1;
        }
	if ($start > -1 && $end > -1) {
	    push (@$positions, [$start-1, $end]);	#start is first position of PMARK so subtract 1
	    $start = -1; $end = -1;
	}
    }

    push(@$positions, [length($sequence), undef]);
    my @pos_order = sort { $a->[0] <=> $b->[0] } @$positions;	#sort based on coordinate position
    map { &$add_contig(@$_); } @pos_order;  # use elements two at a time

    close IN;
    return $contigs;

}

sub make_contigs {
    my ($linker, $sequence) = @_;
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
        $contig->{'id'} = $options{'database_abbreviation'}."." . $CONTIG_STRING . ".".$CONTIG_NUMBER++;
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

    $q = "SELECT f.feature_id, f.uniquename, fl.fmin, fl.fmax, fl.strand, c.name ".
        "FROM feature f, featureloc fl, cvterm c ".
        "WHERE f.feature_id = fl.feature_id ".
        "AND c.cvterm_id = f.type_id AND ".
        "c.name IN ('transcript', 'rRNA', 'tRNA') AND fl.srcfeature_id = ? and f.is_obsolete = 0";
    $queries->{'get_transcripts'} = $DBH->prepare($q);

    $q = "SELECT dx.accession FROM feature f, feature_relationship fr, dbxref dx, db, feature_dbxref fd ".
        "WHERE fr.object_id = f.feature_id and fr.subject_id = ? ".
        "AND f.feature_id = fd.feature_id and fd.dbxref_id = dx.dbxref_id ".
        "AND dx.db_id = db.db_id and db.name = '$LOCUS_DB'";
    $queries->{'get_locus'} = $DBH->prepare( $q );

    $q = "SELECT fp.value FROM featureprop fp, cvterm c ".
        "WHERE fp.type_id = c.cvterm_id ".
        "AND c.name = 'gene_product_name' and fp.feature_id = ?";
    $queries->{'get_gpn'} = $DBH->prepare( $q );

    $q = "SELECT d.accession FROM feature_cvterm fc, cvterm c, cvterm_dbxref cd, cv, dbxref d ".
        "WHERE cv.cv_id = c.cv_id AND cv.name = 'EC' ".
        "AND cd.cvterm_id = c.cvterm_id AND cd.dbxref_id = d.dbxref_id ".
        "AND fc.cvterm_id = c.cvterm_id AND fc.feature_id = ?";
    $queries->{'get_ec'} = $DBH->prepare( $q );

    $q = "SELECT f.feature_id, f.uniquename, fl.fmin, fl.fmax, fl.strand ".
        "FROM feature f, featureloc fl, cvterm c ".
        "WHERE f.type_id = c.cvterm_id AND c.name IN ('tRNA', 'rRNA') ".
        "AND f.feature_id = fl.feature_id AND fl.srcfeature_id = ?";
    $queries->{'get_rna'} = $DBH->prepare( $q );

    $q = "SELECT fp.value FROM featureprop fp, cvterm c ".
        "WHERE fp.type_id = c.cvterm_id ".
        "AND c.name = 'gene_symbol' and fp.feature_id = ?";
    $queries->{'get_gene_symbol'} = $DBH->prepare( $q );

    $q = "SELECT fp.value FROM featureprop fp, cvterm c ".
        "WHERE fp.type_id = c.cvterm_id ".
        "AND c.name = 'name' and fp.feature_id = ?";
    $queries->{'get_name'} = $DBH->prepare( $q );
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

   foreach my $req ( qw(username password database server) ) {
       &_log($ERROR, "Option $req is required") unless( $opts->{$req} );
   }

   # set default values
   $LOCUS_DB = $opts->{'locus_db'} ? $opts->{'locus_db'} : $DEFAULT_LOCUS_DB;
   $LINKER = $opts->{'linker_sequence'} ? $opts->{'linker_sequence'} : $DEFAULT_LINKER_SEQUENCE;
   $OUTPUT_DIR = $opts->{'output_dir'} ? $opts->{'output_dir'} : $DEFAULT_OUTPUT_DIR;
   $CONTIG_STRING = $opts->{'contig_string'} ? $opts->{'contig_string'} : $DEFAULT_CONTIG_STRING;
   $opts->{'database_abbreviation'} = $opts->{'database'} if (!defined($opts->{'database_abbreviation'}));
   if (defined($opts->{'mapping_list'})) {
	$fuzznuc_flag = 1;
	open (MAP, "< $opts->{'mapping_list'}" ) or die("Could not open mapping file list for reading: $!\n" );
	chomp( my @files = <MAP> );
	close (MAP);
	map { 
    	    $mapping_files{$1} = $_ if( m|/([^/]+)\.raw$| );
	} @files;
   }
}

sub init {  
  my($opts) = @_;
  &_connect( $opts->{'username'}, $opts->{'password'}, $opts->{'database'}, $opts->{'server'} );
  my $f = $OUTPUT_DIR."/$opts->{'database'}.tbl";
  open($OFH, "> $f") or die("Can't open $f for writing");
  $f = $OUTPUT_DIR."/$opts->{'database'}.fsa";
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

#!/usr/local/bin/perl

=head1 NAME

infernal.pl - Turns infernal raw output into bsml. 

=head1 SYNOPSIS

USAGE: template.pl
            --input_file=/path/to/some/transterm.raw
            --output=/path/to/transterm.bsml
            --project=aa1
            --id_repository=/some/id_repository/dir
            --query_file_path=/input/file.fsa
            --gzip_output=1
          [ --log=/path/to/file.log
            --debug=4
            --help
          ]

=head1 OPTIONS

B<--input_file,-i>
    The input file (should be prosite scan output)

B<--output,-o>
    Where the output bsml file should be

B<--project,-p>
    Used in id generation.  It's the first token in the id.  (Ex. project.class.number.version)

B<--id_repository,-r>
    Used to make the ids (See Workflow::IdGenerator for details)

B<--query_file_path,-g>
    Path to the query file (input fasta file) for infernal.

B<--gzip_output,-g>
    A non-zero value will result in compressed bsml output.  If no .gz is on the end of the bsml output name, one will
    be added.

B<--log,-l>
    In case you wanted a log file.

B<--debug,-d>
    There are no debug statements in this program.  Sorry.

B<--help,-h>
    Displays this message.

=head1  DESCRIPTION

    Reads in infernal output and produces a bsml representation of the matches.  

=head1  INPUT

    The raw output of infernal.  

=head1  OUTPUT

    Generates a BSML document representing the ps_scan matches.

=head1  CONTACT

    Kevin Galens
    kgalens@tigr.org

=cut


use lib (@INC,$ENV{"PERL_MOD_DIR"});
no lib "$ENV{PERL_MOD_DIR}/i686-linux";
no lib ".";

use strict;
use warnings;
use BSML::BsmlBuilder;
use Workflow::IdGenerator;
use Ergatis;:Logger;
use Getopt::Long qw(:config no_ignore_case no_auto_abbrev);
#use Pod::Usage;

###############GLOBALS######################
my %options = ();                     #Options hash
my $input;
my $output;
my $doc = new BSML::BsmlBuilder();    #Bsml Builder object
my $idMaker;                          #Id generator object
my $project;
my $gzip;
my $defline;
############################################


#Get the options.
my $results = GetOptions (\%options, 
                          'input|i=s',
                          'output|o=s',
                          'project|p=s',
                          'id_repository|r=s',
                          'query_file_path|q=s',
                          'gzip_output|g=s',
                          'log|l=s',
                          'command_id=s',       ## passed by workflow
                          'logconf=s',          ## passed by workflow (not used)
                          'debug=s',
                          'help|h') || pod2usage();


#Make the logger
my $logfile = $options{'log'} || Ergatis;:Logger::get_default_logfilename();
my $logger = new Ergatis;:Logger('LOG_FILE'=>$logfile,
				  'LOG_LEVEL'=>$options{'debug'});
$logger = $logger->get_logger();

#If the help option is used, spit out documentation
&_pod if( $options{'help'} );

#Check in input parameters and set up some variables.
&check_parameters(\%options);

#Parse the input file
my $rawStructure = &parseInfernalRaw($input);

#Create a bsml document out of the data
&createBsml($rawStructure);

#Write the bsml file.
$doc->write($output, '', $gzip);

###################################### SUBROUTINES ################################

#This is the parsing function.  Kinda gross.
sub parseInfernalRaw {
    my $inputFile = shift;
    my @prevLines;
    my $infHit;
    my $retval;

    open(IN, "< $inputFile") or &_die("Unable to open input $inputFile");
    
    while(<IN>) {
        #A crappy (har, har) regex.
        if(/^\shit\s.*?(\d+).*?:\s+(\d+)\s+(\d+)\s+([.\d]+)/) {
            my ($hitNo, $start, $stop) = ($1,$2,$3);
            $infHit->{'bit_score'} = $4;

            $start--; #For interbase numbering

            #Set all the stuff and things
            if($prevLines[1] =~ /sequence\:\s+(.*)\:\:(\d+)-(\d+)/) {
                $infHit->{'seqId'} = $1;
                $start+=($2-1);
                $stop+=($2-1);
            } 

            $infHit->{'cmId'} = $1 if($prevLines[0] =~ /cmsearch\s.*\/(.*?\.cm)\s+/);
            $infHit->{'strand'} = 0;  #0 means forward strand.

            $infHit->{'domain_num'} = $hitNo;
            
            if($start > $stop) {
                my $tmp = $start;
                $start = $stop;
                $stop = $tmp;
                $infHit->{'strand'} = 1;
            }            
            $infHit->{'start'} = $start;
            $infHit->{'stop'} = $stop;

            $infHit->{'runlength'} = $stop-$start;

            my $curLine=$_;
            my ($cmStart, $cmStop);
            my $cmLine = 1;
            
            HIT: while(<IN>) {
                if(/^\s+(\d+)/ && !defined($cmStart) && $cmLine) {
                    $cmStart = $1-1;
                } 
                if(/^\s+\d+.*?(\d+)\s*$/ && $cmLine) {
                    $cmStop = $1;
                } 
                if(/\sCPU\stime/) {
                    last HIT;
                }
                $cmLine = (($cmLine-1)**2) if(/^\s+\d/);
                
            }

            $_ = $curLine;
            $infHit->{'comprunlength'} = $cmStop-$cmStart;

            
            #print Dumper($infHit);
            my %tmpHash = %{$infHit};
            push(@{$retval}, \%tmpHash);

        } else {
            if(@prevLines == 2) {
                shift @prevLines;
                push(@prevLines, $_);
            } elsif(@prevLines < 2) {
                push(@prevLines, $_);
            } else {
                &_die("Collecting too many lines");
            }
        }

     }
    close(IN);

    $doc->createAndAddAnalysis(
                               id => "infernal_analysis",
                               sourcename => $options{'input'},
                               );

    return $retval;

}

#######GENERATE BSML (helper functions follow)#############
sub createBsml {    
    my $infernalRaw = shift;
    my %querySeqs;
    my %cmSeqs;
    my %spas;
    my %fts;
    my %countHits;
    
    foreach my $match (@{$infernalRaw}) {
        #Has the query seq been added?
        &addQuerySeq(\%querySeqs, \%fts, $match);
        
            
        #Make sure the covariance model has been added as a sequence
        &addCoModel(\%cmSeqs, $match);
        

        #Add the Sequence Pairs
        &addSeqPair(\%spas, $match);
        
        #Add the feature elements.  For each match we want a gene, exon, CDS, and rna
        my $featureGroup;                        

        
        #print "About to make an id from project $project and type $type\n";
        my $id = $idMaker->next_id( project => $project, type => 'ncRNA' );

        #See if we can parse out a useful title
        my $title = $match->{'cmId'};
        $title = &getTitle($match->{'cmId'});

        
        #print "Creating a feature ($id, $type)\n";
        my $feat = $doc->createAndAddFeature($fts{$match->{'seqId'}}, $id, $title, 'ncRNA');
        #print "About to addBsmlLink\n";
        $feat->addBsmlLink('analysis', '#infernal_analysis', 'computed_by');
        #print "Adding intervalLoc\n";
        $feat->addBsmlIntervalLoc($match->{'start'}, $match->{'stop'}, $match->{'strand'});
        #print "Add the $type to the feature group\n";
        
        #print "Finished and writing.\n";
        
    }
}

sub addQuerySeq {
    my ($querySeqs, $fts, $match) = @_;
    
    unless($querySeqs->{$match->{'seqId'}}) {
        $querySeqs->{$match->{'seqId'}}  = 
            $doc->createAndAddSequence($match->{'seqId'},undef, 
                                       undef, 'dna', 'assembly');
        $querySeqs->{$match->{'seqId'}}->addBsmlLink('analysis', '#infernal_analysis', 'input_of');
        $querySeqs->{$match->{'seqId'}}->addBsmlAttr('defline', $defline);
        $fts->{$match->{'seqId'}} = 
            $doc->createAndAddFeatureTable($querySeqs->{$match->{'seqId'}});
    }
    
}

sub addCoModel {
    my ($cmSeqs, $match) = @_;

    unless($cmSeqs->{$match->{'cmId'}}) {
        $cmSeqs->{$match->{'cmId'}} = 
            $doc->createAndAddSequence($match->{'cmId'}, undef,
                                       undef, 'rna', 'covariance_model');
        $cmSeqs->{$match->{'cmId'}}->addBsmlLink('analysis', '#infernal_analysis', 'input_of');
    }

}

sub addSeqPair {
    my($spas, $match) = @_;

    unless($spas->{$match->{'seqId'}.$match->{'cmId'}}) {
        $spas->{$match->{'seqId'}.$match->{'cmId'}} = 
            $doc->createAndAddSequencePairAlignment( refseq   => $match->{'seqId'},
                                                     compseq  => $match->{'cmId'},
                                                     complength => "",
                                                     class => "match",
                                                     refstart => 0,);
    }
    
    my $spr = $doc->createAndAddSequencePairRun(alignment_pair => 
                                                $spas->{$match->{'seqId'}.$match->{'cmId'}},
                                                runscore => $match->{'score'},
                                                runlength => $match->{'runlength'},
                                                comprunlength => $match->{'comprunlength'},
                                                refpos => $match->{'start'},
                                                refcomplement => $match->{'strand'},
                                                comppos => 0,
                                                compcomplement => 0,
                                                );

    $doc->createAndAddBsmlAttribute($spr, 'class', 'match_part');
    $doc->createAndAddBsmlAttribute($spr, bit_score => $match->{'bit_score'});


}

#Given our current default location for RFAM HMMs and CMs
# were searching for a more informative title.
sub getTitle {
    my $cmId = shift;
    my $hmmDir = '/usr/local/db/RFAM/HMMs/';
    my $retval = "";
    
    my $cm = $cmId;
    $cm = $1 if($cmId =~ /^([^.]+)/);
    
    opendir(DIR, $hmmDir) || die "can't opendir $hmmDir: $!";
    my @files = grep { /$cm\.INFO/ } readdir(DIR);
    closedir(DIR);

    if(@files > 0) {
        open(IN, "< $hmmDir$files[0]") or &_die("Unable to open file $files[0]");
        while(<IN>) {
            if(/^\#=GF\sTP\s+(.*)/) {
                $retval = $1;
            }
            
        }
        close(IN);
    }
    
    return $retval;
}
#############END OF BSML GENERATION#####################

sub check_parameters {
    
    #input must be passed and must exist
    if($options{'input'}) {
        &_die("input option ($options{input}) does not exist") unless(-e $options{'input'});
    } else {
        &_die("input option was not passed and is required");
    }
    $input = $options{'input'};

    #output must be passed
    &_die("output option was not passed and is required") unless($options{'output'});
    $output = $options{'output'};

    #the id_repository should be passed (perhaps it should also exist, but whatever).
    unless($options{'id_repository'}) {
        &_die("option id_repository is required (for id generation).".
              " See Workflow::IdGenerator for more information");
    }
    $idMaker = new Workflow::IdGenerator( id_repository => "$options{'id_repository'}" );
    
    #Project option must be passed
    unless($options{'project'}) {
        &_die("project option is required");
    }
    $project = $options{'project'};

    #If the query file path was given, parse out the definition line.
    if($options{'query_file_path'}) {
        open(IN, "<$options{query_file_path}") or
            &_die("Unable to open $options{query_file_path}");
        
        while(<IN>) {
            chomp;
            if(/^>(.*)/) {
                $defline = $1;
                last;
            }
        }
        close(IN);
    }

}

sub _pod {
    pod2usage( {-exitval=>0, -verbose => 2, -output => \*STDOUT} );
}

#DIE!
sub _die {
    my $msg = shift;
    $logger->logdie($msg);
}
######EOF###############################

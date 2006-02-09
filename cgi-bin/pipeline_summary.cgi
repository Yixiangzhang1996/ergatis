#!/usr/local/bin/perl -w

use strict;
use CGI;
use CGI::Carp qw(fatalsToBrowser);
use Date::Manip;
use File::stat;
use Monitor;
use POSIX;
use XML::Twig;

my $q = new CGI;
my $repository_root;

print $q->header( -type => 'text/html' );

## will be like:
## /usr/local/scratch/annotation/TGA1/Workflow/split_fasta/29134_test2/pipeline.xml

my $pipeline = $q->param("pipeline") || die "pass pipeline";
my $project;
my $pipelineid;
if ( $pipeline =~ m|(.+/(.+?))/Workflow/pipeline/(\d+)/| ) {
    $repository_root = $1;
    $project = $2;
    $pipelineid = $3;
} else {
    die "failed to extract a repository_root from $pipeline.  expected a Workflow subdirectory somewhere."
}

my $lockdir = "$repository_root/workflow_config_files";
my ($pid,$hostname,$execuser,$retries) = &parselockfile("$lockdir/pid.$pipelineid");
$pid = "" if(!$pid);
$execuser = "unknown" if(!$execuser);
$hostname = "unknown" if(!$hostname);

my $twig = new XML::Twig;

if ($pipeline =~ /(.+)\/Workflow/ ) {
    $repository_root = $1;
}

$twig->parsefile($pipeline);

my $commandSetRoot = $twig->root;
my $commandSet = $commandSetRoot->first_child('commandSet');

## pull desired info out of the root commmandSet
## pull: project space usage

my $state = 'unknown';
if ( $commandSet->first_child('state') ) {
    $state  = $commandSet->first_child('state')->text();
}

my ($starttime, $endtime, $runtime) = &time_info( $commandSet );

## endtime can be null
$endtime = '?' unless $endtime;

my $filestat = stat($pipeline);
my $user = getpwuid($filestat->uid);
my $lastmodtime = time - $filestat->mtime;
$lastmodtime = strftime( "%H hr %M min %S sec", reverse split(/:/, DateCalc("today", ParseDate(DateCalc("now", "- ${lastmodtime} seconds")) ) ));

## quota information (only works if in /usr/local/annotation/SOMETHING)
my $quotastring = 'quota information currently disabled';
#my $quotastring = '';
#if ($pipeline =~ m|^(/usr/local/annotation/.+?/)|) {
#    $quotastring = `getquota -N $1`;
#    if ($quotastring =~ /(\d+)\s+(\d+)/) {
#        my ($limit, $used) = ($1, $2);
#        $quotastring = sprintf("%.1f", ($used/$limit) * 100) . "\% ($used KB of $limit KB used)";
#    } else {
#        $quotastring = 'error parsing quota information';
#    }
#} else {
#    $quotastring = 'unavailable (outside of project area)';
#}

print <<PipelineSummarY;
    <div id='pipeline'>$pipeline</div>
        <div class='pipelinestat' id='pipelinestart'><strong>start:</strong> $starttime</div>
        <div class='pipelinestat' id='pipelineend'><strong>end:</strong> $endtime</div>
        <div class='pipelinestat' id='pipelinelastmod'><strong>last mod:</strong> $lastmodtime</div><br>
        <div class='pipelinestat' id='pipelinestate'><strong>state:</strong> $state</div>
        <div class='pipelinestat' id='pipelineuser'><strong>user:</strong> $user</div>
        <div class='pipelinestat' id='pipelineruntime'><strong>runtime:</strong> $runtime</div>
        <div class='pipelinestat' id='pipelineretry'><strong>retries:</strong> $retries</div>
        <div class='pipelinestat' id='pipelineexec'><strong>exec host:</strong> <a href='http:$hostname:8080/ergatis/view_workflow_pipeline.cgi?instance=$pipeline'>$execuser\@$hostname</a>:$pid</div><br>
        <div class='pipelinestat'><strong>project:</strong> <span id='projectid'>$project</span></div>
        <div class='pipelinestat' id='projectquota'><strong>quota:</strong> $quotastring</div>
        <div class='pipelinestat' id='pipelineid'><strong>pipeline id:</strong> $pipelineid</div>
    <div class='timer' id='pipeline_timer_label'></div>
    <div id='pipelinecommands'>
        <a href='./pipeline_list.cgi?repository_root=$repository_root'><img class='navbutton' src='/ergatis/button_blue_pipeline_list.png' alt='pipeline list' title='pipeline list'></a>
        <a href='./new_pipeline.cgi?repository_root=$repository_root'><img class='navbutton' src='/ergatis/button_blue_new.png' alt='new' title='new'></a>
         <a href='./run_wf.cgi?instancexml=$pipeline&validate=0&pipelineid=$pipelineid&lockdir=$lockdir&'><img class='navbutton' src='/ergatis/button_blue_rerun.png' alt='rerun' title='rerun'></a>  
       <a href='./show_pipeline.cgi?xmltemplate=$pipeline&edit=1'><img class='navbutton' src='/ergatis/button_blue_edit.png' alt='edit' title='edit'></a>
    <a href='./kill_wf.cgi?instancexml=$pipeline'><img class='navbutton' src='/ergatis/button_blue_kill.png' alt='kill' title='kill'></a>
      <a href='http://htc.tigr.org/antware/cgi-bin/sgestatus.cgi' target='_blank'><img class='navbutton' src='/ergatis/button_blue_grid_info.png' alt='grid info' title='grid info'></a>
        <a href='/cgi-bin/ergatis/view_formatted_xml_source.cgi?file=$pipeline' target='_blank'><img class='navbutton' src='/ergatis/button_blue_xml.png' alt='View XML' title='View XML'></a>
    </div>
PipelineSummarY







sub parselockfile{
    my($file) = @_;
    if(-e $file){
	open FILE, "$file" or die "Can't open lock file $file";
	my(@elts) = <FILE>;
	close FILE;
	chomp(@elts);
	my $pid = $elts[0];
	my $hostname = $elts[1];
	my $getpwuid = $elts[2];
	my $retries = $elts[3];
	return ($pid,$hostname,$getpwuid,$retries);
    }
    return undef;
}

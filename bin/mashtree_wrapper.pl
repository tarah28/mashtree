#!/usr/bin/env perl
# Author: Lee Katz <lkatz@cdc.gov>
# Uses Mash and BioPerl to create a NJ tree based on distances.
# Run this script with -h for help and usage.

use strict;
use warnings;
use Data::Dumper;
use Getopt::Long;
use File::Temp qw/tempdir tempfile/;
use File::Basename qw/basename dirname fileparse/;
use File::Copy qw/cp mv/;
use List::Util qw/shuffle/;

use Fcntl qw/:flock LOCK_EX/;

use threads;
use Thread::Queue;
use threads::shared;

use FindBin;
use lib "$FindBin::RealBin/../lib";
use Mashtree qw/logmsg @fastqExt @fastaExt createTreeFromPhylip/;
use Mashtree::Db;
use Bio::SeqIO;
use Bio::TreeIO;
use Bio::Tree::DistanceFactory;
use Bio::Tree::Statistics;
use Bio::Matrix::IO;

local $0=basename $0;
my $writeStick :shared;  # Only one thread can write at a time
my $gzipStick  :shared;  # Only one thread can write at a time

exit main();

sub main{
  my $settings={};
  my @wrapperOptions=qw(help outmatrix=s tempdir=s reps=i numcpus=i);
  GetOptions($settings,@wrapperOptions) or die $!;
  $$settings{reps}||=0;
  $$settings{numcpus}||=1;
  die usage() if($$settings{help});
  die usage() if(@ARGV < 1);

  $$settings{tempdir}||=tempdir("MASHTREE_WRAPPER.XXXXXX",CLEANUP=>1,TMPDIR=>1);
  mkdir($$settings{tempdir}) if(!-d $$settings{tempdir});
  logmsg "Temporary directory will be $$settings{tempdir}";

  if($$settings{reps} < 10){
    logmsg "WARNING: You have very few reps planned on this mashtree run. Recommended reps are at least 10 or 100.";
  }
  
  ## Catch some options that are not allowed to be passed
  # Tempdir: All mashtree temporary directories will be under the
  # wrapper's tempdir.
  if(grep(/^\-+tempdir$/,@ARGV) || grep(/^\-+t$/,@ARGV)){
    die "ERROR: tempdir was specified for mashtree but should be an option for $0";
  }
  # Numcpus: this needs to be specified in the wrapper and will
  # appropriately be transferred to the mashtree script
  if(grep(/^\-+numcpus$/,@ARGV) || grep(/^\-+n$/,@ARGV)){
    die "ERROR: numcpus was specified for mashtree but should be an option for $0";
  }
  # Outmatrix: the wrapper script needs to control where
  # the matrix goes because it can only have the outmatrix
  # for the observed run and not the replicates for speed's
  # sake.
  if(grep(/^\-+outmatrix$/,@ARGV) || grep(/^\-+o$/,@ARGV)){
    die "ERROR: outmatrix was specified for mashtree but should be an option for $0";
  }
  
  # Copy reads over to the temp storage where I assume it is faster
  # and where we can write .lock files.
  my $inputdir = "$$settings{tempdir}/input";
  mkdir $inputdir;
  for(my $i=0;$i<@ARGV;$i++){
    if(-e $ARGV[$i]){
      logmsg "Copying $ARGV[$i] to temp space - $inputdir";
      my $copiedFile = "$inputdir/".basename($ARGV[$i]);
      cp($ARGV[$i], $copiedFile);
      $ARGV[$i] = $copiedFile;
    }
  }

  my $mashOptions=join(" ",@ARGV);
  
  # Some filenames we'll expect
  my $observeddir="$$settings{tempdir}/observed";
  my $obsDistances="$observeddir/distances.phylip";
  my $observedTree="$$settings{tempdir}/observed.dnd";
  my $outmatrix="$$settings{tempdir}/observeddistances.tsv";

  # Make the observed directory and run Mash
  mkdir($observeddir);
  system("$FindBin::RealBin/mashtree --outmatrix $outmatrix.tmp --tempdir $observeddir --numcpus $$settings{numcpus} $mashOptions > $observedTree.tmp");
  die if $?;
  mv("$observedTree.tmp",$observedTree) or die $?;
  mv("$outmatrix.tmp",$outmatrix) or die $?;

  # Multithreaded reps
  my $repQueue=Thread::Queue->new(1..$$settings{reps});
  my @thr;
  for(0..$$settings{numcpus}-1){
    $thr[$_]=threads->new(\&repWorker, $mashOptions, $repQueue, $settings);
    $repQueue->enqueue(undef);
  }

  my @bsTree;
  for(@thr){
    my $treeArr=$_->join;
    for(@$treeArr){
      push(@bsTree,Bio::TreeIO->new(-file=>$_)->next_tree);
    }
  }
  
  # Combine trees into a bootstrapped tree and write it 
  # to an output file. Then print it to stdout.
  logmsg "Adding bootstraps to tree";
  my $biostat=Bio::Tree::Statistics->new;
  my $guideTree=Bio::TreeIO->new(-file=>"$observeddir/tree.dnd")->next_tree;
  my $bsTree=$biostat->assess_bootstrap(\@bsTree,$guideTree);
  for my $node($bsTree->get_nodes){
    next if($node->is_Leaf);
    my $id=$node->bootstrap||$node->id||0;
    $node->id($id);
  }
  open(my $treeFh,">","$$settings{tempdir}/bstree.dnd") or die "ERROR: could not write to $$settings{tempdir}/bstree.dnd: $!";
  print $treeFh $bsTree->as_text('newick');
  print $treeFh "\n";
  close $treeFh;

  system("cat $$settings{tempdir}/bstree.dnd"); die if $?;

  if($$settings{'outmatrix'}){
    cp($outmatrix,$$settings{'outmatrix'});
  }
  
  return 0;
}

sub repWorker{
  my($mashOptions,$repQueue,$settings)=@_;

  my @argv = split(/\s+/, $mashOptions);

  my @bsTree;
  while(defined(my $rep=$repQueue->dequeue())){
    my $repTempdir="$$settings{tempdir}/rep$rep";
    mkdir $repTempdir;
    logmsg "Starting mashtree replicate $rep - $repTempdir";
    
    my @opts;
    #logmsg "Downsampling reads (replicate $rep).";
    # Downsample the reads
    for my $argv(@argv){
      if(! -e $argv){
        push(@opts, $argv);
        next;
      }

      my $newReads = "$repTempdir/".basename($argv);
      my @buffer = ();
      open(my $lockFh, ">", "$argv.lock") or die "ERROR: could not make lockfile $argv.lock: $!";
      flock($lockFh, LOCK_EX) or die "ERROR locking file $argv.lock: $!";

      open(my $inFh, "zcat $argv | ") or die "ERROR reading $argv for downsampling: $!";
      open(my $outFh," | gzip -c > $newReads") or die "ERROR gzipping to $newReads: $!";
      while(my $id=<$inFh>){
        my $seq =<$inFh>;
        my $plus=<$inFh>;
        my $qual=<$inFh>;
        if(rand(1) < 0.5){
          push(@buffer, $id.$seq.$plus.$qual);
          if(scalar(@buffer) > 10000){
            print $outFh join("",@buffer);
            @buffer = (); # flush the buffer
          }
        }
      } 
      # Finish the remaining entries in the buffer
      print $outFh join("",@buffer);
      close $outFh;
      close $inFh;
      close $lockFh;

      push(@opts, $newReads);
    }

    logmsg "Done downsampling for replicate $rep. Running mashtree on files in $repTempdir";
    my $log = `mashtree --numcpus 1 @opts 2>&1 > $repTempdir/tree.dnd`;
    if($?){
      die "ERROR with mashtree on rep $rep (exit code $?):\n$log";
    }

    logmsg "Finished with rep $rep";
    push(@bsTree,"$repTempdir/tree.dnd");
  }

  return \@bsTree;
}

#######
# Utils
#######

sub usage{
  my $usage="$0: a wrapper around mashtree.
  Usage: $0 [options] [-- mashtree options] *.fastq.gz *.fasta > tree.dnd
  --outmatrix          ''   Output file for distance matrix
  --reps               0    How many bootstrap repetitions to run;
                            If zero, no bootstrapping.
                            Bootstrapping will only work on compressed fastq
                            files.
  --numcpus            1    This will be passed to mashtree and will
                            be used to multithread reps.
  
  --                        Used to separate options for $0 and mashtree
  MASHTREE OPTIONS:\n".
  # Print the mashtree options starting with numcpus,
  # skipping the tempdir option.
  `mashtree --help 2>&1 | grep -A 999 "TREE OPTIONS" | grep -v ^Stopped`;

  return $usage;
}


#!/usr/bin/perl
#######################################################
# Author  :  Aurelie Kapusta (https://github.com/4ureliek), with the help of Edward Chuong
# email   :  4urelie.k@gmail.com  
# Purpose :  Writen to test enrichment of TEs in a set of simple features (ChIP-seq for example) 
#######################################################
use strict;
use warnings;
use Carp;
use Getopt::Long;
use Bio::SeqIO;
use Statistics::R; #required to get the Binomial Test p-values

use vars qw($BIN);
use Cwd 'abs_path';
BEGIN { 	
	$BIN = abs_path($0);
	$BIN =~ s/(.*)\/.*$/$1/;
	unshift(@INC, "$BIN/Lib");
}
use TEshuffle;

#-----------------------------------------------------------------------------
#------------------------------- DESCRIPTION ---------------------------------
#-----------------------------------------------------------------------------
#flush buffer
$| = 1;

my $version = "3.1";
my $scriptname = "TE-analysis_Shuffle_bed.pl";
my $changelog = "
#	- v1.0 = Mar 2016 
#            based on TE-analysis_Shuffle_v3+.pl, v3.3, 
#            but adapted to more general input files = bed file corresponding to any features to test.
#	- v2.0 = Mar 2016 
#            attempt of making this faster by removing any length info and allowing overlaps 
#            of shuffled features (since they are independent tests, it's OK)
#            Also added the possibility of several files to -e and -i
#   - v2.1 = Oct 2016
#            remove empty column of length info from output
#            get enrichment by age categories if age file provided
#            bug fix for total counts of hit features when upper levels (by class or family, by Rname was probably OK)
#            Changes in stats, bug fix; use R for the binomial test
#	- v3.0 = Oct 25 2016
#            TEshuffle.pm for subroutines shared with the shuffle_bed script
#	- v3.1 = Nov 03 2016
#            Bug fix - keys for age were being defined even when no age file
\n";

my $usage = "
Synopsis (v$version):

    perl $scriptname -f features.bed [-o <nt>] -s features_to_shuffle [-n <nb>] 
             -r <genome.range> [-b] -e <genome.gaps> [-d] [-i <include.range>] [-a] [-w <bedtools_path>] 
            [-l <if_nonTE>] [-t <filterTE>] [-c] [-g <TE.age.tab>] [-v] [-h]

    /!\\ REQUIRES: Bedtools, at least v18 (but I advise updating up to the last version)
    /!\\ Previous outputs, if any, will be moved as *.previous [which means previous results are only saved once]

  CITATION:
    - the GitHub link to this script, and you may also cite Kapusta et al. (2013) PLoS Genetics (DOI: 10.1371/journal.pgen.1003470) for now
    - for BEDtools, Quinlan AR and Hall IM (2010) Bioinformatics (DOI: 10.1093/bioinformatics/btq033)

  DESCRIPTION:
    Features provided in -s will be overlapped with -i file (which must be simple intervals in bed format), 
       without (no_boot) or with (boot) shuffling (on same chromosome)
       One feature may overlap with several repeats and all are considered.
       Note that because TEs are often fragmented + there are inversions, the counts of TEs are likely inflated;
       this also means that when TEs are shuffled, there are more fragments than TEs. Some should be moved non independently, 
       or the input file should be corrected when possible to limit that issue [not implemented in this script for now]
       
    If you need to generate the <genome.gaps> file but you would also like to add more files to the -e option, 
       just do a first run with no bootstraps (in this example the genome.range is also being generated):
       perl ~/bin/$scriptname -f input.bed -s genome.out -r genome.fa -b -e genome.fa -d -n 0

    Two-tailed permutation test ans a binomial test are done on the counts of overlaps. 
       The results are in a .stats.txt file. Note that high bootstraps takes a lot of time. 
       Binomial is more sensitive.
       Note that for low counts, expected and/or observed, stats likely don't mean much.
  
  MANDATORY ARGUMENTS:	
    -f,--feat     => (STRING) ChIPseq peaks, chromatin marks, etc, in bed format
                              /!\\ Script assumes no overlap between peaks
    -s,--shuffle  => (STRING) Features to shuffle = TE file
                              For now, can only be the repeat masker .out or the .bed file generated by the TE-analysis_pipeline script
                              See -l and -t for filters                
    -r,--range    => (STRING) To know the maximum value in a given chromosome/scaffold. 
                              File should be: Name \\t length
                              Can be files from UCSC, files *.chrom.sizes
                              If you don't have such file, use -b (--build) and provide the genome fasta file for -r                               
    -e,--excl     => (STRING) This will be used as -excl for bedtools shuffle: \"coordinates in which features from -i should not be placed.\"
                              More than one file may be provided (comma separated), they will be concatenated 
                              (in a file = first-file-name.cat.bed).
                              By default, at least one file is required = assembly gaps, and it needs to be the first file
                              if not in bed format. Indeed, you may provide the UCSC gap file, with columns as:
                                  bin, chrom, chromStart, chromEnd, ix, n, size, type, bridge
                              it will be converted to a bed file. Additionally, you may provide the genome file in fasta format
                              and add the option -d (--dogaps), to generate a bed file corresponding to assembly gaps.
                              Other files may correspond to regions of low mappability, for example for hg19:
                              http://www.broadinstitute.org/~anshul/projects/encode/rawdata/blacklists/hg19-blacklist-README.pdf
                              Notes: -> when the bed file is generated by this script, any N stretch > 50nt will be considered as a gap 
                                        (this can be changed in the load_gap subroutine)         
                                     -> 3% of the shuffled feature may overlap with these regions 
                                        (this can be changed in the shuffle subroutine).
  OPTIONAL ARGUMENTS:
    -o,--overlap  => (INT)    Minimal length (in nt) of intersection in order to consider the TE included in the feature.
                              Default = 10 (to match the TEanalysis-pipeline.pl)
    -n,--nboot    => (STRING) number of bootsraps with shuffled -s file
                              Default = 100 for faster runs; use higher -n for good pvalues 
                              (-n 10000 is best for permutation test but this will take a while)
                              If set to 0, no bootstrap will be done
    -b,--build    => (BOOL)   See above; use this and provide the genome fasta file if no range/lengths file (-r)
                              This step may take a while but will create the required file	
    -d,--dogaps   => (BOOL)   See above; use this and provide the genome fasta file if no gap file (-g)
                              If several files in -e, then the genome needs to be the first one.
                              This step is not optimized, it will take a while (but will create the required file)                       

  OPTIONAL ARGUMENTS FOR BEDTOOLS SHUFFLING:
    -i,--incl     => (STRING) To use as -incl for bedtools shuffle: \"coordinates in which features from -i should be placed.\"
                              Bed of gff format. Could be intervals close to TSS for example.
                              More than one file (same format) may be provided (comma separated), 
                              they will be concatenated (in a file = first-file-name.cat.bed)
    -a,--add      => (BOOL)   to add the -noOverlapping option to the bedtools shuffle command line, 
                              and therefore NOT allow overlaps between the shuffled features.
                              This may create issues mostly if -i is used (space to shuffle may be too small to shuffle features)
    -w,--where    => (STRING) if BEDtools are not in your path, provide path to BEDtools bin directory

   OPTIONAL ARGUMENTS FOR TE FILTERING: 
    -l,--low      => (STRING) To set the behavior regarding non TE sequences: all, no_low, no_nonTE, none
                                 -t all = keep all non TE sequences (no filtering)
                                 -t no_low [default] = keep all besides low_complexity and simple_repeat
                                 -t no_nonTE = keep all except when class = nonTE
                                 -t none = everything is filtered out (nonTE, low_complexity, simple_repeat, snRNA, srpRNA, rRNA, tRNA/tRNA, satellite)
    -t,--te       => (STRING) <type,name>
                              run the script on only a subset of repeats. Not case sensitive.
                              The type can be: name, class or family and it will be EXACT MATCH unless -c is chosen as well
                              ex: -a name,nhAT1_ML => only fragments corresponding to the repeat named exactly nhAT1_ML will be looked at
                                  -a class,DNA => all repeats with class named exactly DNA (as in ...#DNA/hAT or ...#DNA/Tc1)
                                  -a family,hAT => all repeats with family named exactly hAT (so NOT ...#DNA/hAT-Charlie for example)
    -c,--contain  => (BOOL)   to check if the \"name\" determined with -filter is included in the value in Repeat Masker output, instead of exact match
                              ex: -a name,HERVK -c => all fragments containing HERVK in their name
                                  -a family,hAT -c => all repeats with family containing hAT (...#DNA/hAT, ...#DNA/hAT-Charlie, etc)
    -g,--group    => (STRING) provide a file with TE age: 
                                 Rname  Rclass  Rfam  Rclass/Rfam  %div(avg)  lineage  age_category
                              At least Rname and lineage are required (other columns can be \"na\"),
                              and age_category can be empty. But if age_category has values, it will 
                              be used as well. Typically:
                                  TE1  LTR  ERVL-MaLR  LTR/ERVL-MaLR  24.6  Eutheria  Ancient
                                  TE2  LTR  ERVL-MaLR  LTR/ERVL-MaLR   9.9  Primates  LineageSpe
  
   OPTIONAL ARGUMENTS (GENERAL): 
    -v,--version  => (BOOL)   print the version
    -h,--help     => (BOOL)   print this usage
\n";


#-----------------------------------------------------------------------------
#------------------------------ LOAD AND CHECK -------------------------------
#-----------------------------------------------------------------------------

my ($input,$shuffle,$exclude,$dogaps,$build,$dobuild,$f_regexp,$allow,$nooverlaps,$v,$help);
my $inters = 10;
my $nboot = 10;
my $incl = "na";
my $nonTE = "no_low";
my $filter = "na";
my $TEage = "na";
my $bedtools = "";
my $opt_success = GetOptions(
			 	  'feat=s'		=> \$input,
			 	  'shuffle=s'   => \$shuffle,
			 	  'overlap=s'   => \$inters,
			 	  'nboot=s'     => \$nboot,
			 	  'range=s'     => \$build,
			 	  'build'       => \$dobuild,
			 	  'excl=s'		=> \$exclude,
			 	  'dogaps'      => \$dogaps,
			 	  'incl=s'		=> \$incl,
			 	  'add'		    => \$nooverlaps,
			 	  'low=s'		=> \$nonTE,
			 	  'te=s'		=> \$filter,
			 	  'contain'     => \$f_regexp,
			 	  'group=s'     => \$TEage,
			 	  'where=s'     => \$bedtools,
			 	  'version'     => \$v,
			 	  'help'		=> \$help,);

#Check options, if files exist, etc
die "\n --- $scriptname version $version\n\n" if $v;
die $usage if ($help);
die "\n SOME MANDATORY ARGUMENTS MISSING, CHECK USAGE:\n$usage" if (! $input || ! $shuffle || ! $build || ! $exclude);
die "\n -f $input is not a bed file?\n\n" unless ($input =~ /\.bed$/);
die "\n -l $input does not exist?\n\n" if (! -e $input);
die "\n -s $shuffle is not in a proper format (not .out, .bed, .gff or .gff3)?\n\n" unless (($shuffle =~ /\.out$/) || ($shuffle =~ /\.bed$/) || ($shuffle =~ /\.gff$/) || ($shuffle =~ /\.gff3$/));
die "\n -s $shuffle does not exist?\n\n" if (! -e $shuffle);
die "\n -r $build does not exist?\n\n" if (! -e $build);
die "\n -e $exclude does not exist?\n\n" if (($exclude !~ /,/) && (! -e $exclude)); #if several files, can't check existence here
die "\n -i $incl does not exist?\n\n" if (($incl ne "na") && ($incl !~ /,/) && (! -e $incl)); #if several files, can't check existence here
die "\n -n $nboot but should be an integer\n\n" if ($nboot !~ /\d+/);
die "\n -i $inters but should be an integer\n\n" if ($inters !~ /\d+/);
die "\n -w $bedtools does not exist?\n\n" if (($bedtools ne "") && (! -e $bedtools));
die "\n -t requires 2 values separated by a coma (-t <name,filter>; use -h to see the usage)\n\n" if (($filter ne "na") && ($filter !~ /,/));
die "\n -g $TEage does not exist?\n\n" if (($TEage ne "na") && (! -e $TEage));
($dogaps)?($dogaps = "y"):($dogaps = "n");
($dobuild)?($dobuild = "y"):($dobuild = "n");
($f_regexp)?($f_regexp = "y"):($f_regexp="n");
$bedtools = $bedtools."/" if (($bedtools ne "") && (substr($bedtools,-1,1) ne "/")); #put the / at the end of path if not there
($nooverlaps)?($nooverlaps = "-noOverlapping"):($nooverlaps = "");

#-----------------------------------------------------------------------------
#----------------------------------- MAIN ------------------------------------
#-----------------------------------------------------------------------------
#Prep steps
print STDERR "\n --- $scriptname v$version\n";

#Genome range
print STDERR " --- loading build (genome range)\n";
my ($okseq,$build_file) = TEshuffle::load_build($build,$dobuild);

#Files to exclude for shuffling
print STDERR " --- getting ranges to exclude in the shuffling of features from $exclude\n";
my @exclude = ();
if ($exclude =~ /,/) {
	($dogaps eq "y")?(print STDERR "     several files provided, -d chosen, genome file (fasta) should be the first one\n"):
	                 (print STDERR "     several files provided, assembly gaps should be the first one\n");
	@exclude = split(",",$exclude) if ($exclude =~ /,/);
} else {
	$exclude[0] = $exclude;
}
$exclude[0] = TEshuffle::load_gap($exclude[0],$dogaps);
print STDERR "     concatenating files for -e\n" if ($exclude =~ /,/);
my $excl;
($exclude =~ /,/)?($excl = TEshuffle::concat_beds(\@exclude)):($excl = $exclude[0]);

#If relevant, files to include for shuffling
if (($incl ne "na") && ($incl =~ /,/)) {
	print STDERR " --- concatenating $incl files to one file\n";
	my @include = split(",",$incl);
	$incl = TEshuffle::concat_beds(\@include);
}

#Load TEage if any
print STDERR " --- Loading TE ages from $TEage\n";
my $age = ();
$age = TEshuffle::load_TEage($TEage,$v) unless ($TEage eq "na");

#Now features to shuffle
print STDERR " --- checking file in -s, print in .bed if not a .bed or gff file\n";
print STDERR "     filtering TEs based on filter ($filter) and non TE behavior ($nonTE)\n" unless ($filter eq "na");
print STDERR "     + getting genomic counts for each repeat\n";
my ($toshuff_file,$parsedRM) = TEshuffle::RMtobed($shuffle,$okseq,$filter,$f_regexp,$nonTE,$age,"y");

#Outputs
my $stats;
my ($f_type,$f_name) = split(",",$filter) unless ($filter eq "na");	
($filter eq "na")?($stats = "$input.nonTE-$nonTE.$nboot.boot.stats"):($stats = "$input.nonTE-$nonTE.$f_name.$nboot.boot.stats");		
my ($out,$outb,$temp,$temp_s) = ("$input.no_boot","$input.boot","$input.temp","$toshuff_file.temp");
cleanup_out($out,$outb,$stats,$temp,$temp_s,$nboot,$input);

#Get total number of features in input file (= counting number of lines with stuff in it)
print STDERR " --- Getting number and length of input\n";
my $input_feat = get_features_info($input);
print STDERR "     number of features = $input_feat->{'nb'}\n";

#Join -i file with -s
my $intersectBed = $bedtools."intersectBed";
print STDERR " --- Intersect with command lines:\n";
print STDERR "        $intersectBed -a $toshuff_file -b $input -wo > $temp/no_boot.joined\n";
system "$intersectBed -a $toshuff_file -b $input -wo > $temp/no_boot.joined";

#Process the joined files
print STDERR " --- Check intersections of $input with features in $toshuff_file (observed)\n";
my $no_boot;
$no_boot = check_for_overlap("$temp/no_boot.joined","no_boot",$out,$inters,$input_feat,$no_boot,$age);

#Now bootstrap runs
print STDERR " --- Run $nboot bootstraps now (to get significance of the overlaps)\n";
print STDERR "     with intersect command line similar to the one above, and shuffle command line:\n";
($incl eq "na")?(print STDERR "        ".$bedtools."shuffleBed -i $toshuff_file -excl $excl -f 2 $nooverlaps -g $build -chrom -maxTries 10000\n"):
                (print STDERR "        ".$bedtools."shuffleBed -incl $incl -i $toshuff_file -excl $excl -f 2 $nooverlaps -g $build -chrom -maxTries 10000\n");
my $boots = ();
if ($nboot > 0) {
	foreach (my $i = 1; $i <= $nboot; $i++) {
		print STDERR "     ..$i bootstraps done\n" if (($i == 10) || ($i == 100) || ($i == 1000) || (($i > 1000) && (substr($i/1000,-1,1) == 0)));	
		my $shuffled = TEshuffle::shuffle($toshuff_file,$temp_s,$i,$excl,$incl,$build_file,$bedtools,$nooverlaps);
		system "      $intersectBed -a $shuffled -b $input -wo > $temp/boot.$i.joined";
		$boots = check_for_overlap("$temp/boot.$i.joined","boot.".$i,$outb,$inters,$input_feat,$boots,$age);
		`cat $outb >> $outb.CAT.boot.txt` if (-e $outb);
		`rm -Rf $temp/boot.$i.joined $shuffled`; #these files are now not needed anymore, all is stored
	}
}

#Stats now
print STDERR " --- Get and print stats\n" if ($nboot > 0);
print_stats($stats,$no_boot,$boots,$nboot,$input_feat,$parsedRM,$age,$scriptname,$version) if ($nboot > 0);

#end
print STDERR " --- $scriptname done\n";
print STDERR "     Stats printed in: $stats.txt\n" if ($nboot > 0);
print STDERR "\n";

`rm -Rf $temp $temp_s`; #these folders are not needed anymore

exit;


#-----------------------------------------------------------------------------
#-------------------------------- SUBROUTINES --------------------------------
#-----------------------------------------------------------------------------
#-----------------------------------------------------------------------------
# Cleanup previous outputs
# cleanup_out($out,$outb,$stats,$temp,$temp_s,$nboot);
#-----------------------------------------------------------------------------
sub cleanup_out {
	my ($out,$outb,$stats,$temp,$temp_s,$nboot) = @_;
	`mv $out $out.previous` if (-e $out);
	`mv $outb $outb.previous` if (-e $outb);
	`mv $stats.txt $stats.txt.previous` if (-e $stats.".txt");
	`mv $stats.details.txt $stats.details.txt.previous` if (-e $stats.".details.txt");
	`mv $outb.CAT.boot.txt $outb.CAT.boot.txt.previous` if (-e $outb.".CAT.boot.txt");
	`mv $out.Rname $out.Rname.previous` if (-e $out.".Rname");
	`mv $out.Rfam $out.Rfam.previous` if (-e $out.".Rfam");
	`mv $out.Rclass $out.Rclass.previous` if (-e $out.".Rclass");
	`mv $outb.Rname $outb.Rname.previous` if (-e $outb.".Rname");
	`mv $outb.Rfam $outb.Rfam.previous` if (-e $outb.".Rfam");
	`mv $outb.Rclass $outb.Rclass.previous` if (-e $outb.".Rclass");
	`rm -Rf $temp` if (-e $temp);
	`rm -Rf $temp_s` if (-e $temp_s);
	`mkdir $temp`;
	`mkdir $temp_s` if ($nboot > 0);
	return 1;
}	

#-----------------------------------------------------------------------------
# Get input file info
# my $input_feat = get_features_info($input);
#-----------------------------------------------------------------------------
sub get_features_info {
	my $file = shift;
	my %info = ();		
	my $nb = `grep -c -E "\\w" $file`;
#	my $len = `more $file | awk '{SUM += (\$3-\$2)} END {print SUM}'`; #this assumes no overlaps, trusting user for now
	chomp($nb);
#	chomp($len);
	$info{'nb'} = $nb;
#	$info{'len'} = $len;				
	return(\%info);
}

#-----------------------------------------------------------------------------
# Check overlap with TEs and count for all TEs
# $no_boot = check_for_overlap("$temp/no_boot.joined","no_boot",$out,$inters,$input_feat,$no_boot,$age);
# $boots = check_for_overlap("$temp/boot.$i.joined","boot.".$i,$outb,$inters,$input_feat,$boots,$age);
#-----------------------------------------------------------------------------
sub check_for_overlap {
	my ($file,$fileid,$out,$inters,$input_feat,$counts,$age) = @_;
	my $check = ();
	open(my $fh, "<$file") or confess "\n   ERROR (sub check_for_overlap): could not open to read $file!\n";
	LINE: while(<$fh>){
		chomp(my $l = $_);
		#FYI:
		# chr1	4522383	4522590	1111;18.9;4.6;1.0;chr1;4522383;4522590;(190949381);-;B3;SINE/B2;(0);216;1;1923	.	-	chr1	4496315	4529218	[ID] [score] [strand]
		my @l = split(/\s+/,$l);	
		my $ilen = $l[-1]; #last value of the line is intersection length
		next LINE unless ($ilen >= $inters);
		my @rm = split(";",$l[3]);
		my $Rnam = $rm[9];
		my ($Rcla,$Rfam) = TEshuffle::get_Rclass_Rfam($Rnam,$rm[10]);
		#Increment in the data structure, but only if relevant
		unless ($check->{$l[9]}{'tot'}) {
			($counts->{$fileid}{'tot'}{'tot'}{'tot'}{'tot'})?($counts->{$fileid}{'tot'}{'tot'}{'tot'}{'tot'}++):($counts->{$fileid}{'tot'}{'tot'}{'tot'}{'tot'}=1);
		}	
		unless ($check->{$l[9]}{$Rcla}) {
			($counts->{$fileid}{$Rcla}{'tot'}{'tot'}{'tot'})?($counts->{$fileid}{$Rcla}{'tot'}{'tot'}{'tot'}++):($counts->{$fileid}{$Rcla}{'tot'}{'tot'}{'tot'}=1);
			
		}
		unless ($check->{$l[9]}{$Rcla.$Rfam}) {
			($counts->{$fileid}{$Rcla}{$Rfam}{'tot'}{'tot'})?($counts->{$fileid}{$Rcla}{$Rfam}{'tot'}{'tot'}++):($counts->{$fileid}{$Rcla}{$Rfam}{'tot'}{'tot'}=1);
		}
		unless ($check->{$l[9]}{$Rcla.$Rfam.$Rnam}) {
			($counts->{$fileid}{$Rcla}{$Rfam}{$Rnam}{'tot'})?($counts->{$fileid}{$Rcla}{$Rfam}{$Rnam}{'tot'}++):($counts->{$fileid}{$Rcla}{$Rfam}{$Rnam}{'tot'}=1);	
		}
				
		#Need to check if a feature is counted several times in the upper classes
		$check->{$l[9]}{'tot'}=1;
		$check->{$l[9]}{$Rcla}=1;
		$check->{$l[9]}{$Rcla.$Rfam}=1;
		$check->{$l[9]}{$Rcla.$Rfam.$Rnam}=1;
		#Age categories if any
		if ($age->{$Rnam}) {
			unless ($check->{$l[9]}{'age'}) { #easier to load tot hit with these keys for the print_out sub
				($counts->{$fileid}{'age'}{'cat.1'}{'tot'}{'tot'})?($counts->{$fileid}{'age'}{'cat.1'}{'tot'}{'tot'}++):($counts->{$fileid}{'age'}{'cat.1'}{'tot'}{'tot'}=1); 
				($counts->{$fileid}{'age'}{'cat.2'}{'tot'}{'tot'})?($counts->{$fileid}{'age'}{'cat.2'}{'tot'}{'tot'}++):($counts->{$fileid}{'age'}{'cat.2'}{'tot'}{'tot'}=1); 
			}
			unless ($check->{$l[9]}{$age->{$Rnam}[4]}) {
				($counts->{$fileid}{'age'}{'cat.1'}{$age->{$Rnam}[4]}{'tot'})?($counts->{$fileid}{'age'}{'cat.1'}{$age->{$Rnam}[4]}{'tot'}++):($counts->{$fileid}{'age'}{'cat.1'}{$age->{$Rnam}[4]}{'tot'}=1);
			}
			if (($age->{$Rnam}[5]) && (! $check->{$l[9]}{$age->{$Rnam}[5]})) {
				($counts->{$fileid}{'age'}{'cat.2'}{$age->{$Rnam}[5]}{'tot'})?($counts->{$fileid}{'age'}{'cat.2'}{$age->{$Rnam}[5]}{'tot'}++):($counts->{$fileid}{'age'}{'cat.2'}{$age->{$Rnam}[5]}{'tot'}=1);
			}
			$check->{$l[9]}{'age'}=1;
			$check->{$l[9]}{$age->{$Rnam}[4]}=1;
			$check->{$l[9]}{$age->{$Rnam}[5]}=1;
		}
	}
	close ($fh);		
	#Now print stuff and exit
#	print STDERR "     print details in files with name base = $out\n";	
	print_out($counts,$fileid,$input_feat,$out);	
	return ($counts);
}

#-----------------------------------------------------------------------------
# Print out details of boot and no_boot stuff
# print_out($counts,$feat_hit,$fileid,$type,$out);
#-----------------------------------------------------------------------------
sub print_out {
	my ($counts,$fileid,$input_feat,$out) = @_;	
	foreach my $Rclass (keys %{$counts->{$fileid}}) {
		print_out_sub($fileid,$Rclass,"tot","tot",$counts,$input_feat,$out.".Rclass") if ($Rclass ne "age");
		foreach my $Rfam (keys %{$counts->{$fileid}{$Rclass}}) {
			print_out_sub($fileid,$Rclass,$Rfam,"tot",$counts,$input_feat,$out.".Rfam") if ($Rclass ne "age");			
			foreach my $Rname (keys %{$counts->{$fileid}{$Rclass}{$Rfam}}) {					
				print_out_sub($fileid,$Rclass,$Rfam,$Rname,$counts,$input_feat,$out.".Rname") if ($Rclass ne "age");
				print_out_sub($fileid,$Rclass,$Rfam,$Rname,$counts,$input_feat,$out.".age1") if (($Rclass eq "age") && ($Rfam eq "cat.1"));				
				print_out_sub($fileid,$Rclass,$Rfam,$Rname,$counts,$input_feat,$out.".age2") if (($Rclass eq "age") && ($Rfam eq "cat.2"));
			}
		}
	}
    return 1;
}

#-----------------------------------------------------------------------------
# Print out details of boot and no_boot stuff, bis
#-----------------------------------------------------------------------------
sub print_out_sub {
	my ($fileid,$key1,$key2,$key3,$counts,$input_feat,$out) = @_;
	my $tothit = $counts->{$fileid}{'tot'}{'tot'}{'tot'}{'tot'};
	my $hit = $counts->{$fileid}{$key1}{$key2}{$key3}{'tot'};
	my $unhit = $input_feat->{'nb'}-$hit;
#	my $len = $counts->{$fileid}{$key1}{$key2}{$key3}{'len'}{'tot'};
	open (my $fh, ">>", $out) or confess "ERROR (sub print_out_sub): can't open to write $out $!\n";
				#fileid, class, fam, name, hits, total features loaded, unhit feat, total feat hit all categories, len <= removed length info
	print $fh "$fileid\t$key1\t$key2\t$key3\t$hit\t$input_feat->{'nb'}\t$unhit\t$tothit\n";
	close $fh;
    return 1;
}

#-----------------------------------------------------------------------------
# Print Stats (permutation test + binomial) + associated subroutines
# print_stats($stats,$no_boot,$boots,$nboot,$input_feat,$parsedRM,$age,$scriptname,$version) if ($nboot > 0);
#-----------------------------------------------------------------------------
sub print_stats {
	my ($out,$obs,$boots,$nboot,$input_feat,$parsedRM,$age,$scriptname,$version) = @_;
	
	#get the boot avg values, sds, agregate all values
	#For obs, just have first key = no_boot
	my $exp = get_stats_data($boots,$nboot,$obs,$parsedRM);
	$exp = TEshuffle::binomial_test_R($exp,"bed");
	
	#now print; permutation test + binomial test with avg lengths
	my $midval = $nboot/2;
	open (my $fh, ">", $out.".txt") or confess "ERROR (sub print_stats): can't open to write $out.txt $!\n";	
	print $fh "#Script $scriptname, v$version\n";
	print $fh "#Aggregated results + stats\n";
	print $fh "#Features in input file (counts):\n\t$input_feat->{'nb'}\n";
	print $fh "#With $nboot bootstraps for exp (expected); sd = standard deviation; nb = number; len = length; avg = average\n";
	print $fh "#Two tests are made (permutation and binomial) to assess how significant the difference between observed and random, so two pvalues are given\n";
	print $fh "#For the two tailed permutation test:\n";
	print $fh "#if rank is < $midval and pvalue is not \"ns\", there are significantly fewer observed values than expected \n";
	print $fh "#if rank is > $midval and pvalue is not \"ns\", there are significantly higher observed values than expected \n";
	print $fh "#The binomial test is done with binom.test from R, two sided\n";
	
	print $fh "\n#Level_(tot_means_all)\t#\t#\t#COUNTS\t#\t#\t#\t#\t#\t#\t#\t#\t#\t#\t#\t#\t#\n";
	print $fh "#Rclass\tRfam\tRname\tobs_hits\t%_obs_(%of_features)\tobs_tot_hits\tnb_of_trials(nb_of_TE_in_genome)\texp_avg_hits\texp_sd\t%_exp_(%of_features)\texp_tot_hits(avg)\tobs_rank_in_exp\t2-tailed_permutation-test_pvalue(obs.vs.exp)\tsignificance\tbinomal_test_proba\tbinomial_test_95%_confidence_interval\tbinomial_test_pval\tsignificance\n\n";
	foreach my $Rclass (keys %{$exp}) { #loop on all the repeat classes; if not in the obs then it will be 0 for obs values			
		foreach my $Rfam (keys %{$exp->{$Rclass}}) {			
			foreach my $Rname (keys %{$exp->{$Rclass}{$Rfam}}) {
				#observed
				my ($obsnb,$obsper) = (0,0);
				$obsnb = $obs->{'no_boot'}{$Rclass}{$Rfam}{$Rname}{'tot'} if ($obs->{'no_boot'}{$Rclass}{$Rfam}{$Rname}{'tot'});
				$obsper = $obsnb/$input_feat->{'nb'}*100 unless ($obsnb == 0);
				#expected
				my $expper = 0;
				my $expavg = $exp->{$Rclass}{$Rfam}{$Rname}{'avg'};	
				$expper = $expavg/$input_feat->{'nb'}*100 unless ($expavg == 0);
				#stats
				my $pval_nb = $exp->{$Rclass}{$Rfam}{$Rname}{'pval'};		
				$pval_nb = "na" if (($expavg == 0) && ($obsnb == 0));									
				#Now print stuff
				print $fh "$Rclass\t$Rfam\t$Rname\t";
				print $fh "$obsnb\t$obsper\t$obs->{'no_boot'}{'tot'}{'tot'}{'tot'}{'tot'}\t"; 
				print $fh "$parsedRM->{$Rclass}{$Rfam}{$Rname}\t"; 
				print $fh "$expavg\t$exp->{$Rclass}{$Rfam}{$Rname}{'sd'}\t$expper\t$exp->{'tot'}{'tot'}{'tot'}{'avg'}\t";			
				my $sign = TEshuffle::get_sign($pval_nb);				
				print $fh "$exp->{$Rclass}{$Rfam}{$Rname}{'rank'}\t$pval_nb\t$sign\t";								
				#Binomial
				$sign = TEshuffle::get_sign($exp->{$Rclass}{$Rfam}{$Rname}{'binom_pval'});
				print $fh "$exp->{$Rclass}{$Rfam}{$Rname}{'binom_prob'}\t$exp->{$Rclass}{$Rfam}{$Rname}{'binom_conf'}\t$exp->{$Rclass}{$Rfam}{$Rname}{'binom_pval'}\t$sign\n";	
			}
		}
	}
close $fh;
    return 1;
}

#-----------------------------------------------------------------------------
# Get the stats values 
# my $exp = get_stats_data($boots,$nboot,$obs,$parsedRM);
#-----------------------------------------------------------------------------
sub get_stats_data {
	my ($counts,$nboot,$obs,$parsedRM) = @_;
	my $exp = ();

	#agregate data
	my ($nb_c,$nb_f,$nb_r,$nb_a1,$nb_a2) = ();
	foreach my $round (keys %{$counts}) {
		foreach my $Rclass (keys %{$counts->{$round}}) {
			push(@{$nb_c->{$Rclass}{'tot'}{'tot'}},$counts->{$round}{$Rclass}{'tot'}{'tot'}{'tot'}) if ($Rclass ne "age");	
			foreach my $Rfam (keys %{$counts->{$round}{$Rclass}}) {
				push(@{$nb_f->{$Rclass}{$Rfam}{'tot'}},$counts->{$round}{$Rclass}{$Rfam}{'tot'}{'tot'}) if ($Rclass ne "age");		
				foreach my $Rname (keys %{$counts->{$round}{$Rclass}{$Rfam}}) {
					push(@{$nb_r->{$Rclass}{$Rfam}{$Rname}},$counts->{$round}{$Rclass}{$Rfam}{$Rname}{'tot'}) if ($Rclass ne "age");	
					push(@{$nb_a1->{$Rclass}{$Rfam}{$Rname}},$counts->{$round}{$Rclass}{$Rfam}{$Rname}{'tot'}) if (($Rclass eq "age") && ($Rfam eq "cat.1"));
					push(@{$nb_a2->{$Rclass}{$Rfam}{$Rname}},$counts->{$round}{$Rclass}{$Rfam}{$Rname}{'tot'}) if (($Rclass eq "age") && ($Rfam eq "cat.2"));
				}
			}
		}		
	}
	
	#get avg, sd and p values now => load in new hash, that does not have the fileID
	foreach my $round (keys %{$counts}) {
		foreach my $Rclass (keys %{$counts->{$round}}) {
			$exp = get_stats_data_details($Rclass,"tot","tot",$nb_c->{$Rclass}{'tot'}{'tot'},$exp,$obs,$nboot,$parsedRM) if ($Rclass ne "age");	
			foreach my $Rfam (keys %{$counts->{$round}{$Rclass}}) {
				$exp = get_stats_data_details($Rclass,$Rfam,"tot",$nb_f->{$Rclass}{$Rfam}{'tot'},$exp,$obs,$nboot,$parsedRM) if ($Rclass ne "age");	
				foreach my $Rname (keys %{$counts->{$round}{$Rclass}{$Rfam}}) {
					$exp = get_stats_data_details($Rclass,$Rfam,$Rname,$nb_r->{$Rclass}{$Rfam}{$Rname},$exp,$obs,$nboot,$parsedRM) if ($Rclass ne "age");
					$exp = get_stats_data_details($Rclass,$Rfam,$Rname,$nb_a1->{$Rclass}{$Rfam}{$Rname},$exp,$obs,$nboot,$parsedRM) if (($Rclass eq "age") && ($Rfam eq "cat.1"));
					$exp = get_stats_data_details($Rclass,$Rfam,$Rname,$nb_a2->{$Rclass}{$Rfam}{$Rname},$exp,$obs,$nboot,$parsedRM) if (($Rclass eq "age") && ($Rfam eq "cat.2"));
				}
			}
		}		
	}
		
	$counts = (); #empty this
	return($exp);
}

#-----------------------------------------------------------------------------
# sub get_data
# called by get_stats_data, to get average, sd, rank and p value for all the lists
#-----------------------------------------------------------------------------	
sub get_stats_data_details {
	my ($key1,$key2,$key3,$agg_data,$exp,$obs,$nboot,$parsedRM) = @_;	
	#get average and sd of the expected
	($exp->{$key1}{$key2}{$key3}{'avg'},$exp->{$key1}{$key2}{$key3}{'sd'}) = TEshuffle::get_avg_and_sd($agg_data);
	
	my $observed = $obs->{'no_boot'}{$key1}{$key2}{$key3}{'tot'};
#	print STDERR "FYI: no observed value for {$key1}{$key2}{$key3}{'tot'}\n" unless ($observed);
	$observed = 0 unless ($observed);	
	
	#Get the rank of the observed value in the list of expected + pvalue for the permutation test
	my $rank = 1; #pvalue can't be 0, so I have to start there - that does mean there will be a rank nboot+1
	my @data = sort {$a <=> $b} @{$agg_data};
	EXP: foreach my $exp (@data) {
		last EXP if ($exp > $observed);
		$rank++;
	}	
	$exp->{$key1}{$key2}{$key3}{'rank'}=$rank;
	if ($rank <= $nboot/2) {
		$exp->{$key1}{$key2}{$key3}{'pval'}=$rank/$nboot*2;
	} else {
		$exp->{$key1}{$key2}{$key3}{'pval'}=($nboot+2-$rank)/$nboot*2; #+2 so it is symetrical (around nboot+1)
	}
	
	#Binomial test
	#get all the values needed for binomial test in R => do them all at once
	my $n = $parsedRM->{$key1}{$key2}{$key3} if ($parsedRM->{$key1}{$key2}{$key3});
	$n = 0 unless ($n);
	print STDERR "        WARN: no value for total number (from RM output), for {$key1}{$key2}{$key3}? => no binomial test\n" if ($n == 0);
	my $p = 0;	
	$p=$exp->{$key1}{$key2}{$key3}{'avg'}/$n unless ($n == 0); #should not happen, but could
	$exp->{$key1}{$key2}{$key3}{'p'} = $p;
	$exp->{$key1}{$key2}{$key3}{'n'} = $n;
	$exp->{$key1}{$key2}{$key3}{'x'} = $observed;
	return($exp);
}




package Maint::Util;

use strict;
use warnings;

require Exporter;
our @ISA         = qw(Exporter);
our %EXPORT_TAGS = (
    'all' => [
        qw(
            maint_hostname
            maint_dryrun
	    maint_runcmd
            maint_scriptname
            maint_runwhen
            maint_checkrunon
            maint_lastlocktime
	    maint_checktime
	    maint_parsemods
	    maint_ordermods
	    maint_locatemods
	    maint_mkarchpath
	    maint_mkscriptpath
	    maint_mkpath
	    maint_readhash
	    maint_hostlookup
	    maint_getarch
          )
    ]
);
our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );
our @EXPORT    = qw(
);
our $VERSION = '0.01';
our $dry_run = 0;
our $forced_hostname = undef;


our $lastlocktime = undef;

our %permittedmodifiers = map { $_ => 1 }
	qw(comb arch mode action backup owner group);

use Sys::Hostname;
#use Sys::Hostname::Long;
use Cwd;
use File::Basename;
use IPC::Run3;
use Maint::Log qw(:all);
#DCWuse Maint::Constants qw(:all);
#DCWuse Maint::Arch qw(:all);
use Scalar::Util 'reftype';

=head1 NAME

Maint::Util - utilities for scripts based on Maint

=head1 SYNOPSIS

	maint_hostname
	maint_hostname_long
	maint_dryrun
	maint_runcmd
	maint_scriptname
	maint_runwhen
	maint_checkrunon
	maint_lastlocktime
	maint_checktime
	maint_parsemods
	maint_ordermods
	maint_locatemods
	maint_mkarchpath
	maint_mkscriptpath
	maint_mkpath
	maint_readhash
	maint_hostlookup
	maint_getarch

=head1 EXPORT

None by default, :all will export:

maint_hostname
maint_hostname_long
maint_dryrun
maint_runcmd
maint_scriptname
maint_runwhen
maint_checkrunon
maint_lastlocktime
maint_checktime
maint_parsemods
maint_ordermods
maint_locatemods
maint_mkscriptpath
maint_mkarchpath
maint_mkpath
maint_readhash
maint_hostlookup

=head1 FUNCTIONS

=cut

# Odd functions that don't really fit anywhere

=head2 B<maint_dryrun([boolean:set_dry_run_flag)>

Accessor/Mutator for package global dry_run flag. Takes optional boolean to set
or disable dry run mode.

Returns current dry run flag.

=cut

sub maint_dryrun
{
    my $p_dry_run = shift;
    $dry_run = $p_dry_run if defined $p_dry_run;

    return $dry_run;
}

=head2 B<maint_lastlocktime([int:locktime])>

Accessor/Mutator for package global lastlocktime value. 
Takes optional date as seconds since epoch to set global.

Returns the last lock time of this script.

=cut

sub maint_lastlocktime
{
    my $p = shift;
    $lastlocktime = $p if defined $p;
    return $lastlocktime;
}

=head2 B<maint_runcmd(arrayref:command [, bool:override_dry_run [, errlevel [, stdin [, stdout [, stderr ]]]]])>

Replacement for maint_system(). Uses IPC:Run3.

Runs the command, unless --dryrun is in force.
On non-zero exit from the command, will log at the given error level, and thus
possibly die.
stdin, stdout, stderr supplied optionally in any of the forms supported by IPC::Run3::run3()

May be abbreviated to maint_runcmd(arrayref:command) to meet most common needs.

See caveats below.
 
Parameters:

  command:
     Array ref of command components, eg: [qw(mount -a)]

  override_dry_run: 
     Allow the command to run even if --dryrun is in force.
     Useful for query commands with no side effects.
     Undef is assumed false.

  errlevel:
     Maint::Log::(LOG_ERR|LOG_WARNING|LOG_INFO|LOG_DEBUG): log
     level to issue if the run command exits with a non zero code or
     the command cannot be run.  Defaults to LOG_ERR which is fatal.

  stdin:
     As per IPC::Run3::run3() except that undef is cast to \undef -
     we never want the parent code's stdin used.

  stdout:
     As per IPC::Run3::run3() except that undef is cast to \undef -
     we never want the parent code's stdout used.

  stderr:
     As per IPC::Run3::run3() except that undef is cast to \undef -
     we never want the parent code's stderr used. On command error,
     stderr will be output via a maint_log() message provided that
     stderr has not been supplied as a defined parameter. perror()
     of last system call will be pronted too.

When errlevel is not the fatal LOG_ERR, it returns the actual exit value
of the program run, 0 for success or -1 if --dryrun
prevented the command from running.

=cut

sub maint_runcmd ($;$$$$$)
{
    my ($cmd, $overridedryrun, $errlevel, $stdin, $stdout, $stderr) = @_;
    
    maint_log(LOG_ERR, "cmd is not an array ref")
    	unless (ref $cmd eq 'ARRAY');
    my $cmdstring = join ' ', @$cmd;
    # Explicit to be clear:
    $overridedryrun = 0 unless defined $overridedryrun;
    # What we will treat errors as (from Maint::Log.pm,
    # avail values are: LOG_ERR (die), LOG_WARN (warn and continue)
    # LOG_INFO (info and continue) LOG_DEBUG (debug and continue)
    # For compatability $errlevel=undef => LOG_ERR and $errlevel=1 => LOG_DEBUG
    if (!defined $errlevel || $errlevel == 0)
    {
	    $errlevel = LOG_ERR;
    }
    elsif ($errlevel == 1)
    {
	    $errlevel = LOG_WARNING;
    }
    # Force decoupling of caller's std* handles:
    my $localstderr = '';
    $stdin = \undef unless defined $stdin;
    $stdout = \undef unless defined $stdout;
    $stderr = \$localstderr unless defined $stderr;
    
    if(!$overridedryrun && maint_dryrun())
    {
	maint_log(LOG_DEBUG, "Not running: $cmdstring");
	return -1;
    } else 
    {
	maint_log(LOG_DEBUG, "Running: $cmdstring");
	# mwj -- turn off die redirection for IPC::Run3
	my $diehldr = $SIG{__DIE__};
	$SIG{__DIE__} = 'DEFAULT';
	my $ret = run3($cmd, $stdin, $stdout, $stderr);
	$SIG{__DIE__} = $diehldr;
	my $cmdexit = $? >> 8;
	if (!$ret || $cmdexit != 0) {
		my $perr = $!;
		maint_log($errlevel, "maint_runcmd() failed: $cmdstring: exit=$cmdexit, perror=[$perr], cmd stderr=$localstderr");
	}
	return $cmdexit;
    }
}

=head2 B<maint_hostname([string:override_hostname)>

Returns the short form hostname using Sys::Hostname. If optional parameter is
given, this and future calls to maint_hostname will return this override value.
Useful for testing scripts emulating running on other hosts.

=cut

sub maint_hostname (;$)
{
    my $p = shift;
    $forced_hostname = $p if defined $p;
    if (defined $forced_hostname)
    {
        return $forced_hostname;
    }
    else
    {
	my $hostname = Sys::Hostname::hostname();
	# [dwm] Strip off any domain-name component.  The current host_classes table
	# contains short names, and it won't find data when given a FQDN.
	$hostname =~ s/^([^\.]+)\..*/$1/;
	return $hostname;
    }
}

=head2 B<maint_hostname_long()>

Returns the long form hostname using Sys::Hostname::Long.

=cut

sub maint_hostname_long
{
#  Once libsys-hostname-long-perl package is installed on all computers,
#  We can do the following instead:
#    my $hostname_long = hostname_long;
   my $hostname_long = `/bin/hostname --long`; 
   chomp $hostname_long;
   return $hostname_long;
}


=head2 B<maint_scriptname()>

Will return a derived name for the current script.
Note: should not be called from top-level maint script utility, as it won't 
work.

=cut

sub maint_scriptname
{
    my $progpath = Cwd::abs_path($0);
    my ($name) = ($progpath =~ m#([^/]+/[^/]+)/[^/]+$#);

    # There's a problem with this strategy.  If we were invoked as './maint'
    # from a numbered maint directory, rather than using an absolute path,
    # then the above heuristic breaks.
    if( defined $name && $name ne '.' )
    {
	    return $name;
    }
    maint_log(LOG_ERR, "Unable to determine maint script name; abs_path for $0 is: $progpath.");
    return 'UNKNOWN'; # Failure case - shouldn't happen
}

# Internal for function below
sub _runagain($)
{
    # Returns true if the given maint script should be run again according
    # to cron-* instructions (and last-run timestamp file in /var/run/sysmaint),
    # false otherwise.
    my $base = shift;
    $base = Cwd::abs_path($base);
    my $scriptname = basename($base);
    maint_log(LOG_DEBUG, "Checking cron status for script $scriptname");
    my @crontimes = glob("$base/runwhen/cron-*");
    unless (scalar(@crontimes) >= 1)
    {
	# If no cron-* files exist, return false.
	return 0;
    }

    # Create last-run directory if it doesn't exist.  
    # (Not unlikely if it's a tmpfs.)
    system("mkdir -p /var/run/sysmaint") unless -d "/var/run/sysmaint";

    # Lookup last-run time
    maint_log(LOG_DEBUG, "Checking for existence of /var/run/sysmaint/maint-$scriptname...");
    if( -e "/var/run/sysmaint/maint-$scriptname" )
    {
	my $time    = time;
	my $lastrun = (stat("/var/run/sysmaint/maint-$scriptname"))[9];

	# For each of our cron rules, check to see if any of them
	# instruct a new script execution.  If one does, return 'true'
	# immediately.
CRON:	foreach my $cron (sort (@crontimes))
	{
		my $rule = basename($cron);
		$rule =~ s/^cron-//;
		if ($rule =~ /^(\d+)m$/)
		{
			# This rule specifies that we should run again after
			# N-minutes have elapsed.
			my $threshold = $lastrun + ($1 * 60);
			return 1 if $time > $threshold;
			next CRON;
		}
		elsif( $rule =~ /^(\d{2})(\d{2})hrs$/ )
		{
			# This rule specifies that we should run on or after
			# a specific time of day.
			my( $cron_hr, $cron_min ) = ($1, $2);
			my( $now_hr, $now_min ) = (localtime($time))[2,1];

			# Calculate the time-of-day of both the current time
			# and the target time, in seconds-since-midnight.
			my $now_daytime = ($now_hr * 60 + $now_min) * 60;
			my $cron_daytime = ($cron_hr * 60 + $cron_min) * 60;

			# Calculate the relative difference in seconds between
			# these two times.  
			my $dt = $cron_daytime - $now_daytime;

			# If dt is > 0, we should instead be comparing against
			# that specific time of day *yesterday*, not today.
			$dt -= 86400 if $dt > 0;

			# Finally, calculate the unix timestamp for the
			# the script's requested runtime.
			my $threshold = $time + $dt;

			# If the last-run time is older than the execution
			# time requested, it should be run again now.  
			# Return true.
			return 1 if $lastrun < $threshold;
			next CRON;
		}
		# If we didn't understand the cron format, log that fact here
		# and carry on.
		maint_log(LOG_WARNING, "Did not understand $scriptname cron entry, '$cron'.  Skipping.");
	}
	
	# Cron rules were specified, but none of them indicate a new run is
	# required.  Return false.
	return 0;
    }
    # If there's no last-run file, we need to run the script now.
    maint_log(LOG_DEBUG, "No last-run file exists, returning cron=1");
    return 1;
}
    

# Internal for function below
sub _get_runlist
{
    my $base = shift;
    maint_log(LOG_ERR, "Parameter 1 must be the directory of a maint script")
    	unless defined $base && length $base;
    maint_log(LOG_ERR, "Parameter $base must be a directory") unless -d $base;
    my $rundir = "$base/runwhen";
    maint_log(LOG_DEBUG, "Looking for run entries in $rundir");
    unless (-d $rundir)
    {
        maint_log(LOG_WARNING, "Your script will not run without a populated 'runwhen' directory.");
        return {};
    }
    my $results={};
    $results->{manual} = 1;
    $results->{boot} = -f "$rundir/boot" ? 1 : 0;
    $results->{install} = -f "$rundir/install" ? 1 : 0;
    $results->{cron} = _runagain($base);
    maint_log(LOG_DEBUG, "Run in: cron: " . $results->{cron} . 
	    			"; boot: " . $results->{boot} . 
			       	"; install: " . $results->{install} .
				"; manual: 1");	
    return $results;
}

=head2 B<maint_runwhen(string:maintdir, string:modetime)>

Returns true if the script based at maintdir (which may be relative to cwd)
is set to run at modetime (boot, manual, install, cron-*).

If the mode is 'cron', then it will only return 'true' if, given the last-run
information in /var/run/sysmaint/$base it determines the script should be run
again.

=cut

sub maint_runwhen
{
    my $base = shift;
    my $mode = shift;
    maint_log(LOG_ERR, "maint_runwhen() Parameter 2 must be a mode time")
    	unless defined $mode && length $mode;
    my $r = _get_runlist($base);
    return $r->{$mode} // 0;
}

# Internal for function below
sub _get_runonlist
{
    my $base = shift;
    maint_log(LOG_ERR, "Parameter 1 must be the directory of a maint script")
    	unless defined $base;
    maint_log(LOG_ERR, "Parameter $base must be a directory") unless -d $base;
    my $runondir = maint_mkpath($base, 'runon');
    maint_log(LOG_DEBUG, "Looking for runon entries in $runondir");
    unless (-d $runondir)
    {
        maint_log(LOG_WARNING, "Your maint script $base needs at least a runon/ directory with at least one entry or it's got no chance!");
        return {};
    }
    
    unless( opendir (DIR, $runondir) )
    {
        maint_log(LOG_ERR, "Cannot open directory $runondir for reading");
    }
    my @e = readdir(DIR);
    close (DIR);
    my %r = map {$_ => 1} @e;
    delete $r{'..'} if exists $r{'..'};
    delete $r{'.'} if exists $r{'.'};
    return \%r;
}

=head2 B<maint_checkrunon(string:maintdir, arrayref:classlist)>

Returns true if the script based at maintdir (which may be relative to cwd)
should run based on the classlist of the host.

This grabs the contents of the runon/ dir minus '..' and '.' and then using that
as a list, sees if there is an intersection with the supplied classlist to which 
our hostname belongs.

=cut

sub maint_checkrunon
{
    my $base = shift;
    my $list = shift;
    maint_log(LOG_ERR, "maint_checkrunon() Parameter 2 must be a class list reference") unless defined $list && 
    	reftype ($list) eq 'ARRAY';
    my $r = _get_runonlist($base);
    foreach my $c (@$list)
    {
        if( exists $r->{$c} )
        {
            maint_log(LOG_DEBUG, "Matched runon class $c");
            return 1;
        }
    }
    maint_log(LOG_DEBUG, "Cannot find runon class match");
    return 0;
}


=head2 B<maint_checktime(int:okstart, int:okend)>

Returns true if the current time is within okstart:00 .. okend:59. 
Copes with ranges during the day and during the night - i.e. ones that 
span midnight.

=cut

sub maint_checktime ($$)
{
  my( $okstarthour, $okendhour ) = @_;

  my $hour = (localtime(time()))[2];

  if( $okstarthour < $okendhour )
  {
    # time period is during day - does not span midnight
    return 0 if $hour < $okstarthour || $hour > $okendhour;

  } else
  {
    # time period is during night 
    return 0 if $hour < $okstarthour && $hour > $okendhour;
  }

  return 1;
}

=head2 B<maint_parsemods(string:modstring)>

Parses a string for dotted suffix modifiers and returns a reference
to a concrete structure containing the data collected from the
modifiers.

=cut

sub maint_parsemods ($)
{
  my ($modstring) = basename($_[0]);
  my @strparts = split(/\./, $modstring);
  
  my %data;
  $data{'key'} = shift @strparts;

  foreach my $mod (@strparts)
  {
    my( $key, $value ) = split(/\-/, $mod, 2);
    if( $permittedmodifiers{$key} )
    {
      $data{$key} = $value;
    } else {
      maint_log(LOG_WARNING, "Fake modifier key $key ignored in $modstring");
    }
  }

  return \%data;
}

=head2 B<maint_ordermods(array:modstrings)>

Orders the modified strings given in modstrings into strict
precedence order FOR THIS HOST (i.e., arch-specific at this time. 
Will return a list of lists in this strict order, including
possible list elements where precedence is identical.

=cut

sub maint_ordermods (@)
{
  my @modstrings = @_;
  my @orderedmod;
  foreach my $mod (@modstrings)
  {
    my $modst = maint_parsemods($mod);
    my $nmods = keys %$modst;

    if( exists($modst->{'arch'}) )
    {
      # skip if not a candidate here
      next if $modst->{'arch'} ne maint_getarch();

      if( $nmods > 2)
      {
	push @{$orderedmod[0]}, $mod;
      } else
      {
	push @{$orderedmod[1]}, $mod;
      }
    } elsif( $nmods > 1)
    {
      push @{$orderedmod[2]}, $mod;
    } else
    {
      push @{$orderedmod[3]}, $mod;
    }
  }
  return @orderedmod;
}

=head2 B<maint_locatemods(arrayref:modstrings, subref:filter)>

Return a list of modified strings selected from those provided in
modstrings which match the filter function provides. The filter function
shall assume that $_ contains the expanded record of the modstring
(result of maint_parsemods).

=cut

sub maint_locatemods ($&;)
{
  my( $modstrings, $filter ) = @_;
  return grep {
    local $_ = maint_parsemods($_);
    &$filter;
    # e.g. &$filter = sub {exists($_->{'comb'}) && ($_->{'comb'} eq 'stop')} 
  } @$modstrings;
}

### Base path helpers

=head2 B<maint_mkarchpath(string:arch, list:tail)>

Builds an arch-specific path based on the various settings
the two inputs provided.

=cut

sub maint_mkarchpath ($$)
{
	my ($arch, $tail) = @_;

	my $cattail = File::Spec->catfile(@$tail);
	return File::Spec->catfile(maint_getmaintpath(), $cattail);
}

=head2 B<maint_mkscriptpath(string:arch, list:tail)>

Builds a path rooted at the directory where the caller script is
running from

=cut

sub maint_mkscriptpath ($)
{
	my ($tail) = @_;
	
  	my $cattail = File::Spec->catfile(@$tail);
	return File::Spec->catfile(maint_getscriptpath(), $cattail);
}


=head2 B<maint_mkpath(array:pathelems)>

Builds a relative path. Essentially wraps File::Spec->catfile().

=cut

sub maint_mkpath (@) {
  my (@pathelem) = @_;
  return File::Spec->catfile(@pathelem);
}

=head2 B<%hash = maint_readhash( filename ) >

read a file respresenting a hash (space separated key and value)

=cut

sub maint_readhash ($)
{
	my( $filename ) = @_;
	my %hash = ();
	open( my $fh, '<', $filename ) || return %hash;
	while( <$fh> )
	{
		chomp;
		s/^\s+//; s/\s+$//;
		next if /^#/;
		my( $k, $v ) = split( /\s+/, $_, 2 );
		$hash{$k} = $v;
	}
	return %hash;
}

=head2 maint_hostlookup( $hostname )

Do a DNS hostname lookup of a given hostname.
Returns undef or the IP address of that hostname.
Uses Net::DNS when available, else falls back on gethostbyname()

=cut

my $hostlookup_resolver;

our $netdns_missing;
BEGIN {
	eval { require Net::DNS; };
	$netdns_missing = $@;
}

sub maint_hostlookup ($) {
	my( $hostname ) = @_;
	if( $netdns_missing )
	{
		my $h = gethostbyname( $hostname );
		return defined $h ? inet_ntoa( $h ) : undef;
	} else
	{
		$hostlookup_resolver = Net::DNS::Resolver->new();
		my $query = $hostlookup_resolver->search($hostname);
		if ($query) {
			foreach my $rr ($query->answer) {
				next unless $rr->type eq "A";
				return $rr->address;
			}
		}
		return undef;
	}
}


our $arch; # Architecture cache

=head2 B<maint_getarch())>

This returns the normalized architecture name for this host (x86, amd64, ppc).

=cut

sub maint_getarch ()
{
	return $arch if $arch;
	
	# Some type of UNIX
	$arch = `/bin/uname -m`;
	chomp $arch;
	if( $? != 0 )
	{
		maint_log(LOG_ERR, "Cannot run /bin/uname -m to determine architecture!!");
		return undef;
	}

	if( $arch =~ /^i\d86/ || $arch =~ /^k[6-7]/ )
	{
		$arch = 'x86';
	} elsif( $arch =~ /^k8/ || $arch =~ /x86_64/ )
	{
		$arch = 'amd64';
	}
	return $arch;
}


1;

=head1 AUTHORS

Duncan White E<lt>dcw@doc.ic.ac.ukE<gt>
Don Riden E<lt>driden@doc.ic.ac.ukE<gt>
Matt Johnson E<lt>mwj@doc.ic.ac.ukE<gt>
Lloyd Kamara E<lt>ldk@doc.ic.ac.ukE<gt>
Tim Southerwood E<lt>ts@doc.ic.ac.ukE<gt>
James Moody E<lt>jrm198@doc.ic.ac.ukE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2003-2015 Department of Computing, Imperial College London

=cut

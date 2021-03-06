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
            maint_scriptname
            maint_runwhen
            maint_checkrunon
            maint_lastlocktime
	    maint_checktime
	    maint_mkarchpath
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

our $rundir = undef;		# DCW: comes from ConfigInfo..

our $lastlocktime = undef;

our %permittedmodifiers = map { $_ => 1 }
	qw(comb arch mode action backup owner group);

use Sys::Hostname;
#use Sys::Hostname::Long;
#use Cwd;
use File::Basename;
use File::Path;
use IPC::Run3;

use Maint::Log qw(:all);
use Maint::ConfigInfo qw(:all);

=head1 NAME

Maint::Util - utilities for Maint scripts

=head1 SYNOPSIS

	maint_hostname
	maint_hostname_long
	maint_dryrun
	maint_scriptname
	maint_runwhen
	maint_checkrunon
	maint_lastlocktime
	maint_checktime
	maint_mkarchpath
	maint_mkpath
	maint_readhash
	maint_hostlookup
	maint_getarch

=head1 EXPORT

None by default, :all will export all the above.

=head1 FUNCTIONS

=cut


# Odd functions that don't really fit anywhere

#
# _init_config():
#	Read the rundir information from the ConfigInfo module.  Store it in
#	the module global variable $rundir.
#
sub _init_config ()
{
	unless( defined $rundir )
	{
		$rundir = maint_getconfig( "rundir" );
		$rundir //= "/var/run/sysmaint";
	}
}


#
# my @run = _run_lookup( $scriptname, $type );
#	Internal function to do all $type (runwhen or runon) checking,
#	given a scriptname, look up - if $type is "runwhen", which modes
#	to run that script in; or if $type is "runon", which hostclasses
#	to run that script on.
#
sub _run_lookup ($$)
{
    my( $scriptname, $type ) = @_;
    _init_config();

    $scriptname =~ s/^\d+//;	# remove numeric prefix if given..

    my $run_key = "$scriptname:$type";
    my $run_raw = maint_getconfig( $run_key );

    return () unless $run_raw;

    my @run = split( /\s*,\s*/, $run_raw );
    return @run;
}


=head2 B<maint_dryrun($set_dry_run_flag>
=head2 B<OR my $dryrunflag = maint_dryrun()>

Accessor for package global dry_run flag.
Returns current dry run flag, or sets it.

=cut

sub maint_dryrun
{
    my $p_dry_run = shift;
    $dry_run = $p_dry_run if defined $p_dry_run;
    return $dry_run;
}


=head2 B<maint_lastlocktime( $locktime )>
=head2 B<OR my $locktime = maint_lastlocktime()>

Accessor for package global lastlocktime value. 
Takes optional date as seconds since epoch to set global.

Returns the last lock time of this script.

=cut

sub maint_lastlocktime
{
    my $p = shift;
    $lastlocktime = $p if defined $p;
    return $lastlocktime;
}



=head2 B<maint_hostname( $override_hostname )>
=head2 B<OR my $hostname = maint_hostname()>

If the optional parameter $override_hostname is given, then all future calls
to maint_hostname() will return this override value.
Useful for testing scripts emulating running on other hosts.

Without the optional parameter, returns the short form hostname
(usually using Sys::Hostname) unless a previous override_hostname has been set.
=cut

sub maint_hostname (;$)
{
    my $p = shift;
    $forced_hostname = $p if defined $p;
    return $forced_hostname if defined $forced_hostname;

    my $hostname = Sys::Hostname::hostname();
    # Strip off any domain-name component.  Hostclasses data normally
    # contains short names..
    $hostname =~ s/^([^\.]+)\..*/$1/;
    return $hostname;
}


=head2 B<maint_hostname_long()>

Returns the long form hostname using Sys::Hostname::Long.
Currently this IGNORES the overriden hostname that may have been
set by maint_hostname().  Not at all sure what the right thing to
do would even be in that case!

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


=head2 B<my $name = maint_scriptname()>

Will return a derived name for the current script.
Note: should not be called from top-level maint script utility, as it won't 
work.

=cut

our $_scriptname;	# cache the scriptname in case we cd around later

sub maint_scriptname
{
    return $_scriptname if defined $_scriptname;

    my $progpath = Cwd::abs_path($0);

    #print "debug: scriptname: progpath=$progpath, dollar0=$0\n";

    my( $name ) = ($progpath =~ m#[^/]+/([^/]+)$#);
    #my $name = basename( $progpath );
    $name =~ s/^\d+//;

    $_scriptname = $name;
    return $name;
}


# my $runagain = _runagain( $scriptname, @runwhen );
#	Return true if the given maint script should be run again according
#	to cron-* runwhen entries (and last-run timestamp file in $rundir),
#	false otherwise.
sub _runagain ($@)
{
    my( $scriptname, @runwhen ) = @_;
    maint_debug( "Checking cron status for script $scriptname");

    my @crontimes = grep { /^cron-/ } @runwhen;
    return 0 unless @crontimes;

    # Create last-run directory if it doesn't exist.  
    # (Not unlikely if it's a tmpfs.)
    File::Path::mkpath( [$rundir], 0, 0755 ) unless -d "$rundir";

    # Lookup last-run time
    my $lastrunfile = "$rundir/maint-$scriptname";
    maint_debug( "Checking for existence of $lastrunfile...");
    unless( -e "$lastrunfile" )
    {
        # If there's no last-run file, we need to run the script now.
        maint_debug( "No last-run file exists, returning cron=1");
        return 1;
    }
    my $time    = time;
    my @x       = stat($lastrunfile);
    my $lastrun = $x[9];

    # For each of our cron rules, check to see if any of them
    # requires that we run this script now.  If one does, return
    # 'true' immediately.
    foreach my $rule (sort @crontimes)
    {
    	$rule =~ s/^cron-//;
    	if ($rule =~ /^(\d+)m$/)
    	{
    		# This rule specifies that we should run again after
    		# N-minutes have elapsed.
    		my $threshold = $lastrun + ($1 * 60);
    		return 1 if $time > $threshold;
    		next;
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
    		next;
    	}
    	# If we didn't understand the cron format, log that fact here
    	# and carry on.
    	maint_warning( "Skipping bad $scriptname cron entry '$rule'.");
    }
	
    # Cron rules were specified, but none of them indicate a new run is
    # required.  Return false.
    return 0;
}
    


=head2 B<my $run = maint_runwhen( $scriptname, $modetime )>

Returns true if the script $scriptname is set to run at $modetime
(boot, manual, install, cron-*).

If the mode is 'cron', then it will only return 'true' if, as
well as the $scriptname being set to "run in" (when) one or more cron-*
modes, the script should run again - given the last-run information in
$rundir/$base.

=cut

sub maint_runwhen
{
    my( $scriptname, $mode ) = @_;

    my @runwhen = _run_lookup( $scriptname, 'runwhen' );
    unless( @runwhen )
    {
        maint_warning( "No '$scriptname:runwhen' configuration entry");
        return {};
    }
    my $runwhen = join( ',', @runwhen );
    maint_debug( "Runwhen entries for $scriptname: $runwhen");

    my %runwhen = map { $_ => 1 } @runwhen;
    my %results;
    $results{manual} = 1;
    $results{boot} = $runwhen{boot} ? 1 : 0;
    $results{install} = $runwhen{install} ? 1 : 0;
    $results{cron} = _runagain( $scriptname, @runwhen );
    maint_debug( "Run in: cron: " . $results{cron} . 
	    			"; boot: " . $results{boot} . 
			       	"; install: " . $results{install} .
				"; manual: 1");	
    return $results{$mode} // 0;
}


=head2 B<my $run = maint_checkrunon( $scriptname, $classlist )>

Returns true if the script $scriptname should run based on the
classlist of the current host.

This grabs the contents of the "$scriptname:runon" config entry,
which lists one or more hostclasses on which this script should run,
and sees if there is an intersection with the supplied host classlist
and the runon classlist.

=cut

sub maint_checkrunon
{
    my( $scriptname, $list ) = @_;

    #maint_fatalerror( "maint_checkrunon() Parameter 2 must be a class list reference") unless defined $list && 
    #	ref( $list ) eq 'ARRAY';

    my @runon = _run_lookup( $scriptname, 'runon' );
    unless( @runon )
    {
        maint_warning( "No $scriptname:runon config key" );
        return 0;
    }
    my $run = join( ',', @runon );
    maint_debug( "Runon entries for $scriptname: $run");

    my %runon = map { $_ => 1 } @runon;
    
    foreach my $c (@$list)
    {
        if( $runon{$c} )
        {
            maint_debug( "Matched runon class $c");
            return 1;
        }
    }
    maint_debug( "Cannot find runon class match");
    return 0;
}


=head2 B<my $ok = maint_checktime( $okstart,  $okend )>

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


### Base path helpers

=head2 B<my $path = maint_mkarchpath( $arch, $tail )>

Builds an arch-specific path based on the various settings
the two inputs provided.

=cut

sub maint_mkarchpath ($$)
{
	my( $arch, $tail ) = @_;

	my $maintroot = maint_getconfig( "maintroot" );
	my $cattail = File::Spec->catfile(@$tail);
	return File::Spec->catfile( $maintroot, $cattail);
}

=head2 B<my $path = maint_mkpath(array:pathelems)>

Builds a relative path. Essentially wraps File::Spec->catfile().

=cut

sub maint_mkpath (@) {
  my (@pathelem) = @_;
  return File::Spec->catfile(@pathelem);
}

=head2 B<%hash = maint_readhash( filename ) >

read a file representing a hash (space separated key and value)

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
		maint_fatalerror( "Cannot run /bin/uname -m to determine architecture!!");
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

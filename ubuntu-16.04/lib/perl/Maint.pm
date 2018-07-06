package Maint;
require 5.008;
use strict;
use warnings;
require Exporter;
our @ISA         = qw(Exporter);
our %EXPORT_TAGS = (
	'all' => [
		qw(
		  maint_init
		  maint_exit
		  maint_setdryrun
		  maint_setlogging
		  LOG_QUIET
		  LOG_ERR
		  LOG_WARNING
		  LOG_INFO
		  LOG_DEBUG
		  )
	]
);


our @EXPORT_OK = (@{ $EXPORT_TAGS{'all'} });
our @EXPORT    = qw(
);
our $VERSION    = '0.01';
our $correctly_exited = 1;  # check the script was written correctly.
our $import_all = 0;

sub import
{
	my $thisclass = shift;
	foreach (@_)
	{
		$import_all = 1 if $_ eq ':all';
	}
	local $Exporter::ExportLevel = 1;
	$thisclass->SUPER::import(@_);
}

use File::Basename;
use File::Slurp;
use Data::Dumper;

use Maint::Log qw(:all);
use Maint::Lock qw(:all);
use Maint::Util qw(:all);
use Maint::ScriptArgs qw(:all);
use Maint::ConfigInfo qw(:all);
use Maint::HostClass qw(:all);
use Maint::SafeFile qw(:all);
use Maint::Choose qw(:all);
use Maint::DistSupport qw(:all);
use Maint::Compose qw(:all);

INIT
{
	# Interesting funkery to bless the exports into the parent namespace
	if( $import_all )
	{
		Maint::Log->export_to_level(1,        __PACKAGE__, ':all');
		Maint::Lock->export_to_level(1,       __PACKAGE__, ':all');
		Maint::Util->export_to_level(1,       __PACKAGE__, ':all');
		Maint::ScriptArgs->export_to_level(1, __PACKAGE__, ':all');
		Maint::ConfigInfo->export_to_level(1, __PACKAGE__, ':all');
		Maint::HostClass->export_to_level(1,  __PACKAGE__, ':all');
		Maint::SafeFile->export_to_level(1,   __PACKAGE__, ':all');
		Maint::Choose->export_to_level(1,     __PACKAGE__, ':all');
		Maint::DistSupport->export_to_level(1,__PACKAGE__, ':all');
		Maint::Compose->export_to_level(1,    __PACKAGE__, ':all');
	}
}

=head1 NAME

Maint - master module for Maint tree. Uses special trickery to import 
sub modules exported symbols into the caller's namespace.

=head1 SYNOPSIS

    maint_init
    maint_exit
    maint_setdryrun
    maint_setlogging

=head1 EXPORT

None by default, :all will export all symbols listed above, plus every :all 
group from each included module.

=head1 FUNCTIONS

=cut

our $configdir;			# where the config lives
our $cachedir;			# where to store local src eg /var/cache/minimaint
our %config;			# the config hash
our $distribution;		# lc(lsbid)+'-'+lsbrelease, eg ubuntu-16.04


#
# my %hash = readhash( $filename );
#	read a file representing a hash (space separated key and value)
#
sub readhash ($)
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


#
# loadphase1config();
#	load the compulsory configuration file..
#
sub loadphase1config()
{
	$configdir = $ENV{MM_CONFIG_DIR} // "/etc/minimaint";
	my $file = "$configdir/phase1";	# phase 1 configuration
	%config = readhash( $file );
	die "maint_init: can't read phase 1 config file $file\n"
		unless %config;

	# which distro (eg Ubuntu)
	my $lsbid = $config{lsbid} || die "maint_init: no config lsbid\n";

	# which release of Ubuntu (eg 16.04)
	my $lsbrelease = $config{lsbrelease} ||
		die "maint_init: no config lsbrelease\n";

	$distribution = lc("$lsbid-$lsbrelease");
	$cachedir = $config{cachedir} || die "maint_init: no config cachedir\n";

	my $maintroot = "$cachedir/$distribution";
	$config{maintroot} = $maintroot;

	maint_debug( "maint_init phase1: configdir=$configdir, cachedir=$cachedir" );
}


#
# loadphase2config( $phase2filename );
#	load the second phase compulsory configuration file..
#
sub loadphase2config ($)
{
	my( $phase2filename ) = @_;

	maint_debug( "maint_init phase2: phase2filename=$phase2filename" );

	my %newconfig = readhash( $phase2filename );
	die "maint_init: can't slurp phase 2 config file $phase2filename\n"
		unless %newconfig;
	# merge %newconfig into %config
	@config{keys %newconfig} = values %newconfig;

	$cachedir = $config{cachedir} || die "maint_init: no config cachedir\n";
}


=head2 B<maint_init()>

Must be called exactly once at the beginning of any script using Maint.

=cut

sub maint_init
{
	# load the config..
	loadphase1config();

	my $phase2filename = "$configdir/phase2";
	loadphase2config( $phase2filename );

	# copy $configdir and %config into maint's inner depths..
	maint_setconfig( $configdir, \%config );

	our $correctly_exited = 0;
	my $scriptname = maint_scriptname();    # Get our computed script name
	maint_initarg();                        # Deal with @ARGV
	maint_setlogging();
	maint_initlog($scriptname);             # Set up logging initially
	my $lockname = $scriptname;
	$lockname =~ s#/#_#g;
	maint_lockname($lockname);

	# Get the last lock time
	my $lastlocktime = maint_getlocktime();
	maint_lastlocktime($lastlocktime);
	unless( maint_setlock() )
	{
		maint_warning( "Cannot acquire lock - cancelling this script run");
		$correctly_exited = 1;
		exit();
	}
	maint_debug( "Acquired lock on this script");
	my $scriptpath = Cwd::abs_path($0);
	my $scriptdir  = dirname($scriptpath);
	maint_warning( "Cannot get script base directory")
		unless defined $scriptdir;
	chdir($scriptdir) || maint_fatalerror( "Cannot chdir to [$scriptdir]");
	maint_debug( "chdir'd to $scriptdir");

	# Check if we're to skip based on modetime
	my $mode = maint_getattr('mode');
	unless( maint_runwhen($scriptname, $mode) )
	{
		maint_debug( "Skipping due to skipwhen constraint");
		maint_exit(1);
		exit(0);
	}
	maint_reloadclasses(1);
	my @classlist = maint_listclasses();
	maint_fatalerror( "Cannot get class list") unless @classlist > 0;
	unless( maint_checkrunon($scriptname, \@classlist) )
	{
		maint_debug( "Skipping due to runon constraint");
		maint_exit(1);
		exit(0);
	}
	maint_initsafe($scriptname);

	# If the dryrun flag is set, initialise all modules which understand it.
	maint_setdryrun( maint_getattr('dryrun') );

	# Optional override of the hostname
	maint_hostname( maint_getattr('hostname') )
		if defined maint_getattr('hostname');

	if( maint_getattr('dryrun') )
	{
		maint_info( "This script is in dry run mode. ".
			"Nothing will actually happen. Pass --nodryrun ".
			"if you don't want this" );
	}

	# Write out last-run timestamp.
	# Create timestamp directory if it doesn't already exist.
	my $rundir = maint_getconfig( "rundir" );
	mkdir $rundir, 0755 unless -d $rundir;
	$scriptname =~ s/\//-/;
	open( my $outfh, '>', "$rundir/$scriptname" );
	close( $outfh );
}


=head2 B<maint_exit(optional skiptriggers)>

Must be called at all exit points in a Maint script in lieu of 'exit',
and also at the final termination point of the script.
Run triggers unless a skiptriggers value is given and is true.

=cut

sub maint_exit
{
	my $skiptriggers = @_?shift:0; # optional skip paramater

	# Action any pending triggers as a result of files being updated.
	my $scriptname = maint_scriptname();    # Get our computed script name
	unless( $skiptriggers )
	{
		maint_saferuntriggers()
	  		|| maint_warning( "Problem running safe_action_triggers()");
	}
	unless( maint_clearlock() )
	{
		maint_warning( "Cannot relinquish lock correctly");
	}
	else
	{
		maint_debug( "Relinquished lock on this script");
	}
	maint_closelog();    # Shut down logging with a nice exit message.
	$correctly_exited = 1;
}

=head2 B<maint_setlogging(bool:silent, bool:debug)>

Adjust log level. If you think you want to do this when starting a Maint
script, you probably want maint_init() instead, which will deal with all the
nasty details for you.

=cut

sub maint_setlogging(;$$)
{
	if( maint_getattr('debug') )
	{
		maint_loglevel(LOG_DEBUG);
	}
	elsif( maint_getattr('silent') )
	{
		maint_loglevel(LOG_WARNING);
	}
	else
	{
		maint_loglevel(LOG_INFO);
	}
	maint_logperline(maint_getattr('logperline'));
	maint_colouriselog(maint_getattr('colour'));
	maint_parsablelog(maint_getattr('machineread'));
	maint_tracemode(maint_getattr('trace'));
}

=head2 B<maint_setdryrun(bool:dryrun)>

Propagates the "dryrun" flag. If you think you want to do this when starting 
a Maint script, you probably want maint_init() instead, which will deal 
with all the nasty details for you.

DCW: CHECK whether this code is correct, it ignores $_[0]!
=cut

sub maint_setdryrun ($)
{
	my $dryrun = maint_getattr('dryrun');
	maint_dryrun($dryrun);
	maint_safedryrun($dryrun);
}

END
{
	return if $correctly_exited;

	# Oh dear - someone didn't bother calling maint_exit properly.
	# We'll do it and shout at them...
	maint_warning( "SCRIPT EXITED UNSAFELY -- NO maint_exit() CALL!")
		unless maint_isexitforced();
	maint_exit();
}

=head1 AUTHORS

Duncan White  E<lt>dcw@imperial.ac.ukE<gt>,
Lloyd Kamara  E<lt>ldk@imperial.ac.ukE<gt>,
Matt Johnson  E<lt>mwj@doc.ic.ac.ukE<gt>,
Don Riden     E<lt>driden@doc.ic.ac.ukE<gt>,
David McBride E<lt>dwm@doc.ic.ac.ukE<gt>,
Adam Langley, E<lt>agl@imperialviolet.orgE<gt>,
Tim Southerwood, E<lt>ts@dionic.netE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2003-2018 Department of Computing, Imperial College London

=cut

1;

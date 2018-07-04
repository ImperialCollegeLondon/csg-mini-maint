package Maint::Lock;
use strict;
use warnings;
require Exporter;
our @ISA         = qw(Exporter);
our %EXPORT_TAGS = (
	'all' => [
		qw(
		  maint_lockname
		  maint_getlocktime
		  maint_setlock
		  maint_clearlock
		  )
	]
);
our @EXPORT_OK = (@{ $EXPORT_TAGS{'all'} });
our @EXPORT    = qw(
);
our $VERSION   = '0.01';

use Fcntl qw(:DEFAULT :flock);
use File::Path;
use Maint::Log qw(:all);
use Maint::Util qw(:all);
use Maint::ConfigInfo qw(:all);

our $lock_dir = undef;
our $lock_name = undef;
our $lock_fh   = undef;

=head1 NAME

Maint::Lock - locking implementation for Maint

=head1 SYNOPSIS

    use Maint::Lock qw(:all);

=head1 EXPORT

None by default, :all will export:

maint_setlockname
maint_getlocktime
maint_setlock
maint_clearlock

=head1 DESCRIPTION

This is used to set/check a named lock. All maint lock files are made
inside the lock_dir specified by ConfigInfo's "lockdir" key.

The actual lock is set with an fcntl() so stale files will not register
as a false lock.

=head1 FUNCTIONS

=cut

=head2 B<my $lockname = maint_lockname()>
=head2 B<OR maint_lockname( $lockname )>

Gets (or sets if name is supplied) the name of our script - this will
be used as the name of the lock file in the lock_dir.

=cut

sub maint_lockname
{
	my $p = shift;
	if( defined $p )
	{
		maint_fatalerror( "Bad lock name: $p") unless length $p && $p !~ m/\//;
		$lock_name = $p;
	}
	return $lock_name;
}


#
# _init_config():
#	Read the lockdir information from the ConfigInfo module.  Store it in
#	the module global variable $lock_dir.  By the time this is called,
#	maint_lockname( X ) should have been called, so X should be stored in
#	$lock_name.
#
sub _init_config ()
{
	$lock_dir //= maint_getconfig( "lockdir" );

	maint_fatalerror( "Lock name not set")
	  unless defined $lock_name && $lock_name;
}


=head2 B<my $mtime = maint_getlocktime()>

Returns time last lock was set, undef if never, based on mtime of lock file

=cut

sub maint_getlocktime
{
	_init_config();

	return undef unless -d $lock_dir;

	my $lockfile = "$lock_dir/$lock_name";
	unless( -f $lockfile )
	{
		maint_debug( "Lock file not created before");
		return undef;
	}

	my @x = stat( $lockfile );
	my $mtime = $x[9];
	maint_debug( "Lock file last set at " . localtime($mtime));
	return $mtime;
}


=head2 B<my $ok = maint_setlock()>

Returns TRUE if the lock could be set, FALSE otherwise

=cut

sub maint_setlock
{
	_init_config();

	unless( -d $lock_dir )
	{
		unless( File::Path::mkpath([$lock_dir], 0, 0755) )
		{
			maint_fatalerror( "Unable to create lock dir: $lock_dir");
		}
	}
	my $lockfile = "$lock_dir/$lock_name";
	unless( sysopen($lock_fh, $lockfile, O_WRONLY | O_TRUNC | O_CREAT) )
	{
		maint_fatalerror( "Cannot open lock file $lock_dir/$lock_name - $!");
	}
	unless( flock($lock_fh, LOCK_EX | LOCK_NB) )
	{
		maint_warning( "Cannot get lock: $lock_name - $!");
		return 0;
	}
	maint_warning( "Got lock: $lock_name");
	return 1;
}


=head2 B<my $ok = maint_clearlock()>

Clears the lock. 

Returns TRUE if OK, FALSE otherwise (unlikely).

=cut

sub maint_clearlock
{
	_init_config();

	unless( defined $lock_fh )
	{
		maint_warning( "Lock $lock_name not locked!");
		return 0;
	}
	unless( flock($lock_fh, LOCK_UN) )
	{
		maint_warning( "Cannot release lock: $lock_name - $!");
		return 0;
	}
	unless( close($lock_fh) )
	{
		maint_warning( "Problem closing lock file $lock_name - $!");
	}
	undef $lock_fh;
	maint_debug( "Released lock: $lock_name");
	return 1;
}

=head1 AUTHORS

Duncan White E<lt>dcw@imperial.ac.ukE<gt>,
Lloyd Kamara E<lt>ldk@imperial.ac.ukE<gt>,
Matt Johnson E<lt>mwj@doc.ic.ac.ukE<gt>,
David McBride E<lt>dwm@doc.ic.ac.ukE<gt>,
Adam Langley, E<lt>agl@imperialviolet.orgE<gt>,
Tim Southerwood, E<lt>ts@dionic.netE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2003-2018 Department of Computing, Imperial College London


=cut

1;

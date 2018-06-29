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
our $lock_name = undef;
our $fh        = undef;
use Fcntl qw(:DEFAULT :flock);
use File::Path;
use Maint::Log qw(:all);
use Maint::Util qw(:all);
our $lockdir = "/var/lock/maint";

=head1 NAME

Maint::Lock - locking implementation for Maint

=head1 SYNOPSIS

    use Maint::Lock qw(:all);

=head1 EXPORT

None by default, :all will export:
    maint_setlockname maint_getlocktime maint_setlock maint_clearlock

=head1 DESCRIPTION

This is used to set/check a named lock. A lock file will be made in /var/lock/
The actual lock is set with an fcntl() so stale files will not register as a 
false lock.

=head1 FUNCTIONS

=cut

=head2 B<maint_lockname([string:name])>

Gets (or sets if name is supplied) the name of our script - this will be used as
the name of the lock file in /var/lock.

=cut

sub maint_lockname
{
	my $p = shift;
	if (defined $p)
	{
		maint_log(LOG_ERR, "Bad lock name: $p") unless length $p && $p !~ m/\//;
		$lock_name = $p;
	}
	return $lock_name;
}

=head2 B<maint_getlocktime()>

Returns time last lock was set, undef if never, based on mtime of lock file

=cut

sub maint_getlocktime
{
	maint_log(LOG_ERR, "Lock name not set")
	  unless defined $lock_name && length $lock_name;
	unless (-d $lockdir)
	{
		return undef;
	}
	my (
		$dev,
		$ino,
		$mode,
		$nlink,
		$uid,
		$gid,
		$rdev,
		$size,
		$atime,
		$mtime,
		$ctime,
		$blksize,
		$blocks
	  )
	  = stat(maint_mkpath($lockdir, $lock_name));
	if (defined $mtime)
	{
		maint_log(LOG_DEBUG, "Lock file last set at " . localtime($mtime));
	}
	else
	{
		maint_log(LOG_DEBUG, "Lock file not created before");
	}
	return $mtime;
}

=head2 B<maint_setlock()>

Returns TRUE if the lock could be set, FALSE otherwise

=cut

sub maint_setlock
{
	maint_log(LOG_ERR, "Lock name not set")
	  unless defined $lock_name && length $lock_name;
	unless (-d $lockdir)
	{
		unless (File::Path::mkpath([$lockdir], 0, 0755))
		{
			maint_log(LOG_ERR, "Unable to create lock dir: $lockdir");
		}
	}
	unless (sysopen($fh, maint_mkpath($lockdir, $lock_name), O_WRONLY | O_TRUNC | O_CREAT))
	{
		maint_log(LOG_ERR, "Cannot open lock file $lockdir/$lock_name - $!");
	}
	unless (flock($fh, LOCK_EX | LOCK_NB))
	{
		maint_log(LOG_WARNING, "Cannot get lock: $lock_name - $!");
		return 0;
	}
	maint_log(LOG_WARNING, "Got lock: $lock_name");
	return 1;
}

=head2 B<maint_clearlock()>

Clears the lock. 

Returns TRUE if OK, FALSE otherwise (unlikely).

=cut

sub maint_clearlock
{
	if (!defined($fh)) {
		maint_log(LOG_WARNING, "Lock $lock_name not locked!");
		return 0;
	}
	unless (flock($fh, LOCK_UN))
	{
		maint_log(LOG_WARNING, "Cannot release lock: $lock_name - $!");
		return 0;
	}
	unless (close($fh))
	{
		maint_log(LOG_WARNING, "Problem closing lock file $lock_name - $!");
	}
	undef $fh;
	maint_log(LOG_DEBUG, "Released lock: $lock_name");
	return 1;
}

=head1 AUTHORS

Tim Southerwood E<lt>ts@doc.ic.ac.ukE<gt>,
Matt Johnson E<lt>mwj@doc.ic.ac.ukE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2003-2005 Department of Computing, Imperial College London

=cut

1;

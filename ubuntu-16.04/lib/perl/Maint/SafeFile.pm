package Maint::SafeFile;
use strict;
use warnings;
require Exporter;
our @ISA         = qw(Exporter);
our %EXPORT_TAGS = (
	'all' => [
		qw(
			maint_initsafe
			maint_checkdiskspace
			maint_tmpfile
			maint_tmpdirname
			maint_safeopen
			maint_safeclose
			maint_safeabort
			maint_safelink
			maint_safecopy
			maint_safedryrun
			maint_saferuntriggers
			maint_safeprint
			maint_safedelete
		  )
	]
);
our @EXPORT_OK = (@{ $EXPORT_TAGS{all} });
our @EXPORT    = qw(
);
our $VERSION = '0.01';

use File::Spec;
use Maint::Util qw(:all);

# Package globals
our $maint_safedryrun       = 0;
our $safetriggerfile = '';
our @files_renamed_list = ();          # Used to store the list of every file
				       # changed for real. Upon running the
				       # safe_end() will check against list of
				       # file triggers and run appropriate
				       # actions.
our $tmpdirname         = undef;       # Cache the tmpdir name for cleanup later.
our $scriptname         = 'UNKNOWN';
our $newfile_suffix     = '.tmpnew';
our $oldfile_suffix     = '.old';
our $special_suffix     = '-special';

=head1 NAME

Maint::SafeFile - safe file manipulation for scripts using Maint

=head1 SYNOPSIS

package Maint::SafeFile;

  maint_initsafe
  maint_checkdiskspace
  maint_tmpfile
  maint_tmpdirname
  maint_safeopen
  maint_safeclose
  maint_safeabort
  maint_safelink
  maint_safecopy
  maint_safedryrun
  maint_saferuntriggers
  maint_safeprint
  maint_safedelete

=head1 EXPORT

None by default, :all will export the following subset:

maint_initsafe
maint_safeopen
maint_safeclose
maint_safeabort
maint_safelink
maint_tmpfile
maint_safecopy
maint_safedryrun
maint_saferuntriggers
maint_tmpfile
maint_safedelete

=head1 FUNCTIONS

(Note, in the following documentation, $newfile_suffix = '.tmpnew', 
$oldfile_suffix = '.old' and $special_suffix = '-special'.

=cut

use Maint::Log qw(:all);
use Maint::Util qw(:all);
use POSIX;
use File::stat;
use Fcntl qw(:DEFAULT F_SETFD F_GETFD);
use File::Temp qw(tempfile tempdir);
use File::Compare;
use File::Path;
use File::Slurp;
use JSON;
use File::Basename;

=head2 B<maint_safedryrun([bool:dry_run_flag])>

Returns (and optionally sets) the current dry_run_flag.

=cut

sub maint_safedryrun(;$)
{
	my $p_dry_run = shift;
	$maint_safedryrun = $p_dry_run if defined $p_dry_run;
	return $maint_safedryrun;
}

=head2 B<maint_initsafe( $scriptname )>

Returns (and optionally sets) the current scriptname. Used to make the
maint_tmpdirname() return more traceable directories.

=cut

sub maint_initsafe(;$)
{
	my $p = shift;
	$scriptname = $p if defined $p;
	return $scriptname;
}

=head2 B<my $ok = maint_checkdiskspace( $directory_or_file )>

Returns 1 (TRUE) if there is considered to be reasonable free space on
the filesystem containing the named directory or file. If the directory
does not exist, the parent is checked recursively.
=cut

sub maint_checkdiskspace($)
{
	my $p = shift;
	my $path = $p;

	# Yukky - avoiding a bootstrap problem due to new modules not being
	# available everywhere...
	unless( eval { local $SIG{__DIE__}; require Filesys::Statvfs;} )
	{
		maint_log(LOG_WARNING, "Filesys::Statvfs module not available - freespace check skipped");
		return 1;
	}
	import Filesys::Statvfs;
	unless( -d $path )
	{
		my($volume,$directories,$file) = File::Spec->splitpath( $path );
		my @dirs = File::Spec->splitdir( $directories );
		for( my $c = $#dirs - 1 ; $c >=0; $c-- )
		{
			$path = File::Spec->catdir( @dirs[0..$c] );
			last if -d $path;
			$path = File::Spec->rootdir();
		}
		maint_log(LOG_DEBUG, "$p not a directory or doesn't exist - testing path [$path] instead");
	}
	my( $bsize, $frsize, $blocks, $bfree, $bavail,
	    $files, $ffree, $favail, $fsid, $basetype, $flag,
	    $namemax, $fstr ) = statvfs($path);
	my $available = int($bsize * $bavail / 1024 / 1024);
	if( $available < 50 )
	{
		maint_log(LOG_WARNING, "Filesystem which $path is on only has ${available}MB available, less than the required 50MB");
		return 0;
	}
	if( $favail < 50 )
	{
		maint_log(LOG_WARNING, "Filesystem which $path is on only has $favail inodes available, less than the required 50");
		return 0;
	}
	maint_log(LOG_DEBUG, "Filesystem which $path is on has ${available}MB and $favail  inodes available - OK");
	return 1;
}


#
# _init_config();
#	Read the safefile:triggers information from the ConfigInfo module.
#	Store the filename in the module global variable
#	$safetriggerfile
#
sub _init_config ()
{
	unless( defined $safetriggerfile )
	{
		$safetriggerfile = maint_getconfig( "safefile:triggers" );
	}
}


# Internal to decide if we are allowed to touch the file due to existence of a
# -special suffix. We don't care what type of node the -special is, just
# its existence.
sub _is_special($)
{
	my $file = shift;
	return (-e $file . $special_suffix);
}

# Checks if a path exists and mkdirs it if required - log_error on error
sub _checkandmakedir($)
{
	my $dir = shift;
	maint_log(LOG_ERR, "_checkandmakedir() must have a directory as parameter") unless defined $dir;
	maint_log(LOG_DEBUG, "Checking directory exists: $dir");
	return if -d $dir;
	if (-e $dir)
	{
		maint_log(LOG_ERR, "Cannot make directory $dir, something with that name exists already");
	}
	maint_log(LOG_DEBUG, "Making directory $dir");
	eval { mkpath([$dir], 0, 0755) };
	if ($@)
	{
		maint_log(LOG_ERR, "Cannot create dir $dir");
	}
}

=head2 B<my($fd,$handle) = maint_safeopen( $filename [,$mode=0664 [$uid=0, [, $gid=0 [, $nobackup]]]])>

Returns: ($fd, $handle) where $fd is a file handle that you can use as normal 
and $handle is the handle to pass to maint_safeclose. 

On failure returns (undef,undef).

Creates a temp file in the safe directory as filename with the $newfile_suffix

If any of mode, uid or gid are undef, it will inherit those values from
the original file if it exists, or default to 0644,0,0

If not in dry_run mode, then maint_safeclose() will attempt a POSIXly
atomic rename leaving the original file prefixed with $oldfile_suffix
and the desired file cleanly updated.

If in dry run mode or file$special_suffix exists filename.$newfile_suffix
is created and the original tmpname is never touched.

Until maint_safeclose is called the original file is untouched.

If the path to the file does not exist, required directories are made.

=cut

sub maint_safeopen ($;$$$$)
{
	my( $filename, $mode, $uid, $gid, $nobackup ) = @_;

	_init_config();
	my $h = {};
	local *FD;
	my $basedir = dirname($filename);
	_checkandmakedir($basedir);
	$h->{filename} = $filename;
	unless( $h->{filename} )
	{
		maint_log(LOG_WARNING, "maint_safeopen, zero length filename invalid");
		return (undef, undef);
	}

	# Space check
	
	maint_log(LOG_ERR, "Insufficient space left to open $h->{filename}")
		unless maint_checkdiskspace($h->{filename});

	# Sanity check - we only replace files or symlinks
	if( -e $h->{filename} && !(-l $h->{filename} || -f $h->{filename}) )
	{
		maint_log(LOG_WARNING, "Cannot open $h->{filename} as it's not a file or symlink");
		return (undef, undef);
	}

	$nobackup = 0 unless defined $nobackup;
	# Take mode, uid, 
	unless( defined $mode && defined $uid && defined $gid )
	{
		if( -e $h->{filename} )
		{
			my $s;
			unless( $s = File::stat::stat($h->{filename}) )
			{
				maint_log(LOG_WARNING, "Cannot stat $h->{filename}");
				return (undef, undef);
			}
			$mode //= $s->mode();
			$uid  //= $s->uid();
			$gid  //= $s->gid();
		}
		else
		{
			$mode //= 0644;
			$uid  //= 0;
			$gid  //= 0;
		}
	}
	$h->{mode}     = $mode;
	$h->{uid}      = $uid;
	$h->{gid}      = $gid;
	$h->{nobackup} = $nobackup;
	$h->{tmpname}  = $h->{filename} . $newfile_suffix;
	maint_log(LOG_DEBUG, "Opening $h->{filename} as $h->{tmpname}");

	if( -e $h->{tmpname} )    # Stale or maybe from another parallel
	                         # running process (which shouldn't happen)
	{
		unless( unlink($h->{tmpname}) )
		{
			maint_log(LOG_WARNING, "Cannot unlink [$h->{tmpname}]");
			return (undef, undef);
		}
	}
	unless( sysopen(FD, $h->{tmpname}, O_RDWR | O_EXCL | O_CREAT | O_NOFOLLOW | O_SYNC, $mode) )
	{
		maint_log(LOG_WARNING, "Safefile open failed for [$h->{filename}]: $!");
		return (undef, undef);
	}
	$h->{fd} = *FD;
	maint_log(LOG_DEBUG, sprintf "Setting tmp new file owner=%d.%d, mode=%o", $h->{uid}, $h->{gid}, $h->{mode});
	chmod( $h->{mode}, $h->{tmpname} ) ||
		maint_log(LOG_WARNING, "Cannot chmod $h->{tmpname} - $!");
	if( $> == 0 )
	{
		chown( $h->{uid}, $h->{gid}, $h->{tmpname} ) ||
			maint_log(LOG_WARNING, "Cannot chown $h->{tmpname} - $!");
	}
	return (*FD, $h);
}

=head2 B<my $ok = maint_safeclose( $filehandle_from_maint_safeopen )>

Returns: TRUE on success, FALSE otherwise.

Performs an atomic rename, replacing the tmpname given to maint_safeopen
with the temp file and removing the temp file, unless in a dry run. Will
leave the original file suffixed with $oldfile_suffix

=cut

sub maint_safeclose ($)
{
	my( $h ) = @_;
	my( $uid, $gid );
	close($h->{fd});
	my $update_file = 0;

	maint_log(LOG_ERR, "Insufficient space left to open $h->{filename}")
		unless maint_checkdiskspace($h->{filename});

	# Sanity checks
	unless( $h->{tmpname} && $h->{filename} )
	{
		# Very very bad - one or both of the filenames is zero length
		# Time to bomb - something very odd here
		maint_log(LOG_ERR, "The temp filename or the current filename are zero length");
		return 0;
	}
	unless( -f $h->{tmpname} )
	{
		# This is very bad... Let's bomb now
		maint_log(LOG_ERR, "Cannot find temp file $h->{tmpname}");
		return 0;
	}

	my $oldfile = $h->{filename} . $oldfile_suffix;

	# Do we switch the temp file in place?
	maint_log(LOG_WARNING, "[$h->{filename}] has a -special lockout") if
		_is_special($h->{filename});
	unless( maint_safedryrun() || _is_special($h->{filename}) )
	{
		unless( -e $h->{filename} )
		{
			# New file, don't need to compare anything
			maint_log(LOG_INFO, "Writing new $h->{filename}");
			$update_file = 1;
		}
		else
		{
			# We do have both files, cmp them
			if( compare($h->{tmpname}, $h->{filename}) != 0 )
			{
				maint_log(LOG_INFO, "Updating $h->{filename}");
				$update_file = 1;
			}
			else
			{
				maint_log(LOG_DEBUG, "Unchanged $h->{filename}");
				$update_file = 0;
			}
		}
		if( $update_file ) 	# Really do it
		{
			if( -e $h->{filename} ) # current file to backup?
			{
				if( -e $oldfile )
				{
					unless( unlink( $oldfile ) )
					{
						maint_log(LOG_WARNING, "Cannot unlink old backup $oldfile");
						return 0;
					}
				}
				unless( $h->{nobackup} )
				{
					unless( link($h->{filename}, $oldfile))
					{
						maint_log(LOG_WARNING, "Cannot make backup of $h->{filename}");
						return 0;
					}
					maint_log(LOG_DEBUG, "Making a backup from $h->{filename} to $oldfile");
				}
				else
				{
					maint_log(LOG_DEBUG, "Asked to not make a backup");
				}
			}
			maint_log(LOG_DEBUG, "Renaming $h->{tmpname} to $h->{filename}");

			# Now switch the new temp file over the current one
			unless( rename($h->{tmpname}, $h->{filename}) )
			{
				maint_log(LOG_WARNING, "Cannot replace $h->{filename} with new temp version");
				return 0;
			}
			# Note for checking against triggers later.
			push @files_renamed_list, $h->{filename};
		}
		else    # Cleanup tmpnew file unless it is different.
		{
			if( compare($h->{tmpname}, $h->{filename}) == 0 )
			{
				maint_log(LOG_DEBUG, "Unchanged $h->{filename}");
				if( unlink($h->{tmpname}) )
				{
					maint_log(LOG_DEBUG, "unlinked $h->{tmpname}");
				}
				else
				{
					maint_log(LOG_WARNING, "Error unlinking $h->{tmpname}");
				}
			}
		}
		# Remove any existing backups
		if( $h->{nobackup} && -e $oldfile )
		{
			maint_log(LOG_INFO, "Deleting $oldfile as we don't want backups");
			unless( unlink( $oldfile ) )
			{
				maint_log(LOG_WARNING, "Cannot unlink old backup $oldfile");
			}
		}

		# We'll carry on and fix the modes and ownership regardless
		my $setmsg = sprintf( "Setting file owner=%d.%d, mode=%o", $h->{uid}, $h->{gid}, $h->{mode});
		maint_log(LOG_DEBUG, $setmsg );
		chmod( $h->{mode}, $h->{filename} ) ||
			maint_log(LOG_WARNING, "Cannot chmod $h->{filename} - $!");
		if( $> == 0 )
		{
			chown($h->{uid}, $h->{gid}, $h->{filename}) ||
				maint_log(LOG_WARNING,
					"Cannot chown $h->{filename} - $!");
		}
	}

	# We're OK now
	return 1;
}


=head2 B<my $ok = maint_safeabort( $filehandle_from_maint_safeopen )>

Returns: TRUE on success, FALSE otherwise.

Kills the tmp new file and does not replace the current file.

=cut

sub maint_safeabort ($)
{
	my $h = shift;
	close($h->{fd});

	# Sanity checks
	unless( $h->{tmpname} && $h->{filename} )
	{
		# Very very bad - one or both of the filenames is zero length
		# Time to bomb - something very odd here
		maint_log(LOG_ERR, "The temp filename or the current filename are zero length");
		return 0;
	}
	unless( -f $h->{tmpname} )
	{
		# This is very bad... Let's bomb now
		maint_log(LOG_ERR, "Cannot find temp file $h->{tmpname}");
		return 0;
	}
	unless( unlink($h->{tmpname}) )
	{
		maint_log(LOG_ERR, "Cannot unlink tmp new file: $h->{tmpname}");
		return 0;
	}
	maint_log(LOG_DEBUG, "Aborted file write to $h->{filename}, file untouched");
	return 1;
}


=head2 B<my $ok = maint_safelink( $source, $dest [, $nobackup])>

Creates a symlink called dest pointing at source. Will respect dry_run_flag and
any $special_suffix files, in which case the new link will be named dest$newfile_suffix.

The original file or link will be named dest$oldfile_suffix.

Returns: 1 on success, 0 otherwise.

=cut

sub maint_safelink ($$;$)
{
	my( $src, $dest, $nobackup ) = @_;

	# Sanity checks
	unless( $src )
	{
		maint_log(LOG_WARNING, "maint_safelink, zero length source filename invalid");
		return 0;
	}
	unless( $dest )
	{
		maint_log(LOG_WARNING, "maint_safelink, zero length destination filename invalid");
		return 0;
	}
	maint_log(LOG_ERR, "Insufficient space left to link to $dest") unless maint_checkdiskspace($dest);

	$nobackup = 0 unless defined $nobackup;
	
	# Sanity check - we only replace files or symlinks
	if( -e $dest && !(-l $dest || -f $dest) )
	{
		maint_log(LOG_WARNING, "Will not replace $src as it's not a file or symlink");
		return 0;
	}
	my $symname = $dest . $newfile_suffix;
	# Clear out any current .tmpnew node
	if( -e $symname )
	{
		unless( unlink $symname )
		{
			maint_log(LOG_WARNING, "Cannot unlink old backup $symname");
			return 0;
		}
	}
	unless( symlink($src, $symname) )
	{
		maint_log(LOG_WARNING, "Failed to symlink $src to new temp - $!");
		return 0;
	}
	maint_log(LOG_WARNING, "[$dest] has a -special lockout") if _is_special($dest);
	unless( maint_safedryrun() || _is_special($dest) )
	{
		# Check the content of the new and current symplink to see if we really have to switch them
		unless( -l $symname && -l $dest && (readlink($symname) eq readlink($dest)) )
		{
			if( -e $dest )		# Need to backup original?
			{
				my $olddest = $dest . $oldfile_suffix;
				if( -e $olddest )
				{
					unless( unlink $olddest )
					{
						maint_log(LOG_WARNING, "Cannot unlink old backup $olddest ");
						return 0;
					}
				}
				unless( $nobackup )
				{
					if( -l $dest )
					{
						unless( symlink(readlink($dest), $olddest ) )
						{
							maint_log(LOG_WARNING, "Failed to backup link $src - $!");
							return 0;
						}
					}
					else
					{
						unless( _copyfile($dest, $olddest ) )
						{
							maint_log(LOG_WARNING, "Failed to backup file $src - $!");
							return 0;
						}
					}
				}
			}

			unless( rename($symname, $dest) )
			{
				maint_log(LOG_WARNING, "Failed to rename symlink $src to $dest - $!");
				return 0;
			}
			maint_log(LOG_INFO, "Made symlink $dest pointing at $src");
			# Note for checking against triggers later.
			push @files_renamed_list, $dest;
		}
		else
		{
			# Remove .tmpnew
			if( -e $symname )
			{
				unless( unlink $symname )
				{
					maint_log(LOG_WARNING, "Cannot unlink old backup $symname");
					return 0;
				}
			}
		}
	}
	return 1;
}


=head2 B<maint_tmpdirname()>

Returns: A safe temp tmpdirname.

First this checks and /tmp exists and sets the owner to root.root and the mode
to 01777. It also does this to /var/tmp for good measure.
This creates /tmp/root (if needed) and sets owner root:root and mode 0700. 
It returns a tmpdirname, not a filehandle, which is slightly imperfect, but given 
that it's a trusted directory it's good enough. The tmpdir name has the form:
/tmp/root/scriptname_XXXXXX.

The tmpdirname is cached in memory and will be returned on subsequant calls without 
further checking. The directory is automatically removed by perl when the script
exist (unless kill -9 was involved).

=cut

sub maint_tmpdirname ()
{
	my $prefix = $scriptname;
	$prefix //= 'UNKNOWN';
	return $tmpdirname if defined $tmpdirname && $tmpdirname =~ m/^\/tmp\/root\//;
	# XXX regexp not arch indep
	my @paths = ({path => ['tmp'], mode => 01777}, 
		     {path => ['var', 'tmp'], mode => 01777}, 
		     {path => ['tmp', 'root'], mode => 0700});

	foreach my $path (@paths)
	{
		my $tmppath = maint_mkrootpath(@{$path->{path}});
		# Fix modes of the tmp dirs
		unless (-d $tmppath)
		{
			maint_log(LOG_WARNING, "Making $tmppath - should be here already");
			mkdir($tmppath) ||
				maint_log(LOG_ERR, "Failed to create $tmppath: $!");
		}
		if( $> == 0 )
		{
			chown(0, 0, $tmppath) ||
				maint_log(LOG_ERR,
				  "Failed to set owner/gid of $tmppath: $!");
		}
		chmod($path->{mode}, $tmppath) ||
			maint_log(LOG_ERR, "Failed to set mode $tmppath: $!");
	}

	$tmpdirname = tempdir($prefix . '_XXXXXX', DIR => maint_mkrootpath('tmp', 'root'), CLEANUP => 1);

	maint_log(LOG_ERR, "Insufficient space left to make $tmpdirname") unless maint_checkdiskspace($tmpdirname);
	return $tmpdirname;
}

=head2 B<my( $fd, $name ) = maint_tmpfile([string:prefix])>

This will create a temporary file in maint_tmpdirname() - the filename will be
of the form prefix_XXXXXXXX.tmp

If prefix is not specified, it will be set to UNKNOWN

Returns (FD, name) where FD is an open file handle and name is the name of the
file. Returns undef on error.

Closing the file descriptor does not cause the file to be unlinked.

Note (from perldoc File::Temp) - on unix, you may pass the following
string to another program in order to pass the temporary file by handle:

"/dev/fd/" . fileno( file_descriptor )

or in perl, you may use:

"+<&" . fileno( file_descriptor ) or variants thereof.

=cut

sub maint_tmpfile (;$)
{
	my $prefix = shift;
	$prefix = 'UNKNOWN' unless defined $prefix;
	my( $fh, $file ) = tempfile($prefix . '_XXXXXX',
				SUFFIX => '.tmp',
				UNLINK => 0,
				DIR => maint_tmpdirname());
	maint_log(LOG_DEBUG, "Opened temp file: $file");

	# Now fix the file handle so that is doesn't get closed when spawning subprocesses
	unless( fcntl($fh, F_SETFD, 0) )
	{
		maint_log(LOG_ERR, "Cannot clear close-on-exec flag on temp fh: $!");
	}
	return ($fh, $file);
}

# Internal to do a simple robust copy - _copyfile( $src, $dest [, $mode])
# Ownership will be the uid/gid of the running process at this point
sub _copyfile
{
	my( $src, $dest, $mode ) = @_;
	local *SRC_FD;
	maint_log(LOG_DEBUG, "Copy src: $src, dest: $dest");
	unless( -f $src || -l $src )
	{
		maint_log(LOG_WARNING, "Cannot copy $src to $dest, source file is not a file or a symlink");
		return 0;
	}
	if( -e $dest )
	{
		unless( unlink($dest) )
		{
			maint_log(LOG_WARNING, "Cannot unlink $dest");
			return 0;
		}
	}
	unless( defined $mode )
	{
		my $m = File::stat::stat($src);
		unless( $m )
		{
			maint_log(LOG_WARNING, "Cannot stat file $src");
			return 0;
		}
		$mode = $m->mode() & 0x1fff;
	}
	unless( sysopen(SRC_FD, $src, O_RDONLY, $mode) )
	{
		maint_log(LOG_WARNING, "Cannot open $src for reading - skipping copy - $!");
		return 0;
	}
	unless( sysopen(DEST_FD, $dest, O_RDWR | O_EXCL | O_CREAT | O_NOFOLLOW | O_SYNC, $mode) )
	{
		maint_log(LOG_WARNING, "Cannot open $dest for writing - skipping copy - $!");
		close(SRC_FD);
		return 0;
	}
	unless( _copyfd(*SRC_FD, *DEST_FD) )
	{
		maint_log(LOG_WARNING, "Failed to copy data from $src to $dest");
		close SRC_FD;
		close DEST_FD;
		return 0;
	}
	close SRC_FD;
	close DEST_FD;
	return 1;
}


=head2 B<my $ok = maint_safecopy( $source, $dest [, $mode [, $uid [, $gid [, $nobackup]]]])>

Returns: 1 if success, 0 otherwise.

All of the optional arguments default to the value obtained by statting
source.  Uses the functions in this library to copy a file. This will
respect the dry_run_flag, presence of a $special_suffix file and it
will copy either files or files pointed to by symlinks. It does not
create symlinks.

If the copy is not fully completed due to dry_run_flag or $special_suffix
files, then the copy is left named dest$newfile_suffix as per
maint_safeopen.

The original file is always left named file$oldfile_suffix.

=cut

sub maint_safecopy
{
	my( $src, $dest, $mode, $uid, $gid, $nobackup ) = @_;
	local *SRC_FD;
	maint_log(LOG_DEBUG, "Copy src: $src, dest: $dest");
	unless( -f $src )
	{
		maint_log(LOG_WARNING, "maint_safecopy: src=$src does not exist");
		return 0;
	}
	unless( open(SRC_FD, '<', $src) )
	{
		maint_log(LOG_WARNING, "maint_safecopy: cannot open $src for reading");
		return 0;
	}
	my( $dest_fd, $handle ) = maint_safeopen( $dest, $mode, $uid, $gid, $nobackup );
	unless( defined $dest_fd )
	{
		maint_log(LOG_WARNING, "maint_safecopy: cannot open $dest for writing");
		close SRC_FD;
		return 0;
	}
	unless( _copyfd(*SRC_FD, $dest_fd) )
	{
		maint_log(LOG_WARNING, "Cannot copy $src to $dest");
		close SRC_FD;
		maint_safeabort($handle);
		return 0;
	}
	close SRC_FD;
	maint_safeclose( $handle );
	return 1;
}

# Internal copy from file descript to filedescriptor - robust as possible
sub _copyfd ($$)
{
	my( $src_fd, $dest_fd ) = @_;
	my( $data, $n );
	for(;;)
	{
		$n = sysread($src_fd, $data, 1024 * 1024);
		unless( defined $n )
		{
			maint_log(LOG_WARNING, "Failed to read from file");
			return 0;
		}
		if( $n > 0 )
		{
			my $res = syswrite $dest_fd, $data;
			unless( defined $res )
			{
				maint_log(LOG_WARNING, "Failed to write to file");
				return 0;
			}
			if( $res != length($data) )
			{
				maint_log(LOG_WARNING, "Failed to write the number of bytes we asked for");
				return 0;
			}
		}
		if( $n == 0 )
		{
			maint_log(LOG_DEBUG, "_maint_safecopyfd OK");
			return 1;
		}
	}
}


=head2 B<my $ok = maint_saferuntriggers()>

Returns: 1 if success, 0 otherwise.

For all the files which were sucessfully replaced (file are only replaced
if their contents change) this check each file against the list in the
triggers file and run any trigger actions (no more than once!) in order.

Returns 1 if OK, otherwise 0;

=cut

sub maint_saferuntriggers
{
	_init_config();
	unless( defined $safetriggerfile && $safetriggerfile )
	{
		maint_log(LOG_DEBUG, "No triggers file specified");
		return 0;
	}
        my $confdir = maint_getconfigdir();
        my $triggerfile = "$confdir/$safetriggerfile";
	unless( -f $triggerfile )
	{
		maint_log(LOG_WARNING, "No triggers file $triggerfile");
		return 0;
	}
	my $triggerdata = read_file( $triggerfile );
	my $json = decode_json( $triggerdata );

	my %files_renamed = map { $_ => 1 } @files_renamed_list;
	maint_log(LOG_INFO, "Checking file triggers");
	my @actions     = ();
	foreach my $pair (@$json)
	{
		my $testforfile = $pair->{file};
		my $action = $pair->{action};
		if( exists $files_renamed{$testforfile} )
		{
			maint_log(LOG_DEBUG, "Noted trigger on file $testforfile");
			push @actions, $action;
		}
	}
	my %actionsdone;
	foreach my $act (@actions)
	{
		next if $actionsdone{$act}++;
		if( maint_safedryrun() )
		{
			maint_log(LOG_INFO, "dry_run set: would have run trigger: $act");
			next;
		}
		maint_log(LOG_WARNING, "Would run trigger: $act");
		#maint_log(LOG_DEBUG, "Running trigger: $act");
		#DCWmaint_runcmd([split(/\s+/, $act)], undef, 1); # We only have a string...
	}
	return 1;
}


=head2 B<maint_safeprint( $filehandle, $text)>

Same as print, except write errors will abort with maint_safeabort() and
maint_log(LOG_ERR, )

=cut

sub maint_safeprint
{
	my( $handle, $text ) = @_;
	my $fd = $handle->{fd};
	unless( print $fd $text )
	{
		my $oserr = $!;
		maint_safeabort($handle);
		maint_log(LOG_ERR, "Error writing to file $handle->{filename}");
	}
}

=head2 B<my $ok = maint_safedelete(string:destname)>

Deletes (unlink or rmdir as required) destname. Respects dryrun mode and 
the existence if destname-special, in which case nothing is done.

Does not do recursive deletes (yet).

Returns 1 on success, 0 on failure

=cut

sub maint_safedelete
{
	my( $dest ) = @_;
	maint_log(LOG_DEBUG, "Considering deleting dest: $dest");

	unless( -e $dest || -l $dest )
	{
		maint_log(LOG_INFO, "$dest does not exist, nothing to remove");
		return 0;
	}

	if( maint_safedryrun() )
	{
		maint_log(LOG_INFO, "Want to remove $dest, but we are in dryrun mode");
		return 1;
	}
	
	if( _is_special($dest) )
	{
		maint_log(LOG_WARNING, "Want to remove $dest, but is either protected by $dest-special");
		return 1;
	}
	
	if( -d $dest )
	{
		maint_log(LOG_INFO, "removing directory $dest");
		if( ! rmdir($dest) )
		{
			maint_log(LOG_WARNING, "Failed to remove directory $dest: $!");
			return 0;
		}
		maint_log(LOG_INFO, "Removed directory $dest");
	}
	else 
	{
		maint_log(LOG_INFO, "removing non-directory $dest");
		if( ! unlink($dest) )
		{
			maint_log(LOG_WARNING, "Failed to remove file/node $dest: $!");
			return 0;
		}		
		maint_log(LOG_INFO, "Removed file/node $dest");
	}

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

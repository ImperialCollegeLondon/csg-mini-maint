package Maint::Perms;

use strict;
use warnings;

require Exporter;
our @ISA         = qw(Exporter);
our %EXPORT_TAGS = (
    'all' => [
        qw(
              maint_setperms
          )
    ]
);
our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );
our @EXPORT    = qw(
);
our $VERSION = '0.01';

use Maint::Log qw(:all);
use Maint::HostClass qw(:all);
use Data::Dumper;
use File::Slurp;

=head1 NAME

Maint::Perms - run a "program" written in the "Perms" declarative language

=head1 SYNOPSIS

    use Maint::Perms qw(:all);

    maint_setperms

=head1 EXPORT

None by default, :all will export maint_setperms().

=head1 B<The "Perms" declarative language>

Basic primitives:

loop:

foreach GLOB	<- set current filename to each of the glob results in turn
....		   and execute all the contained selectors and actions for
end		   each glob result.  selectors inside a foreach need no
		   file/dir name

selectors:

dir X   <-- make sure that X exists, as a directory.  if it doesn't exist,
            mkdir it.  if it doesn't but not as a directory, delete it, and
	    then mkdir it.

file X  <- ditto for files..

ifdir D   <- test whether D exists as a directory, if not skip following actions

iffile F  <- test whether F exists as a file, if not skip following actions

ifinclass C  <- test whether this host is in hostclass C, if not skip
		following actions

actions:

perms P   <- set the permissions on the current file/dir name (set by
	     dir/file/ifdir/iffile) to P

owner O	  <- set the owner of the current file/dir to O (number or username)

group G	  <- set the group of the current file/dir to G (number or username)

facl 'F'  <- call setfacl -R -m 'F' on the current file/dir

=cut

=head1 FUNCTIONS

=cut

# Internal functions

sub touch ($)
{
	my( $filename ) = @_;
	open( my $fh, '>', $filename );
	close( $fh );
}

# State machine variables:

my $datafilename;	# the filename of the Perms config file..
my @line;		# the contents of the Perms config file..
my $currpos;		# the current position ("line no") in @line
my $currfile;		# the current file, set by loops and selectors
my $skip;		# are we skipping the current file?
my $foreach_start;	# if we're in a foreach loop, start pos in @line
my @glob;		# if we're in a foreach loop, remaining filenames
my $if_start;		# if we're in an if body, start pos in @line
my $if;			# if we're in an if body, which is it?

# State machine:

sub sm_error ($)
{
	my( $msg ) = @_;
	my $line = $line[$currpos] // "";
	$currpos++;
	maint_warning( "$msg, line $currpos of $datafilename: $line" );
	maint_warning( "Abandoning perms" );
	maint_exit();
	exit(0);
}

# State machine: selectors

sub dir
{
	unlink( $currfile ) if -e $currfile && ! -d $currfile;
	mkdir( $currfile, 0700 ) unless -d $currfile;
}

sub file
{
	unlink( $currfile ) if -e $currfile && ! -f $currfile;
	touch( $currfile ) unless -f $currfile;
}

sub ifdir
{
	unless( defined $if_start )
	{
		$if_start = $currpos;
		$if       = "ifdir";
		$skip     = 0;
	}
	$skip = 1 unless -d $currfile;
}

sub iffile
{
	unless( defined $if_start )
	{
		$if_start = $currpos;
		$if       = "iffile";
		$skip     = 0;
	}
	$skip = 1 unless -f $currfile;
}

sub ifinclass
{
	unless( defined $if_start )
	{
		$if_start = $currpos;
		$if       = "ifinclass";
		$skip     = 0;
	}
	$skip = 1 unless maint_isinclass( $currfile );
}

my %isselector = (
	dir       => \&dir,
	file      => \&file,
	ifdir     => \&ifdir,
	iffile    => \&iffile,
	ifinclass => \&ifinclass,
);


# State machine: actions

sub perms ($)
{
	my( $perms ) = @_;
	my $p = oct($perms);
	my @s = stat($currfile);
	return if ($s[2] & 07777) == $p;
	maint_info( "Setting permissions of $currfile to $perms" );
	chmod( $p, $currfile );
}

sub owner ($)
{
	my( $owner ) = @_;
	my $o = $owner;
	unless( $o =~ /^\d/ )
	{
		my($login,$pass,$uid,$gid) = getpwnam($o);
		$o = $uid;
	}
	my @s = stat($currfile);
	return if $s[4] == $o;
	maint_info( "Setting owner of $currfile to $owner" );
	chown( $o, -1, $currfile );
}

sub group ($)
{
	my( $group ) = @_;
	my $g = $group;
	unless( $g =~ /^\d/ )
	{
		my $gid = getgrnam($g);
		$g = $gid;
	}
	my @s = stat($currfile);
	return if $s[5] == $g;
	maint_info( "Setting group of $currfile to $group" );
	chown( -1, $g, $currfile );
}

# should test whether the facl is already set..
sub facl ($)
{
	my( $facl ) = @_;
	#maint_info( "Setting facl of $currfile to $facl" );
	system( "/usr/bin/setfacl -R -m '$facl' $currfile" )
}

my %isaction = (
	perms  => \&perms,
	owner  => \&owner,
	group  => \&group,
	facl   => \&facl,
);


sub foreach ($)
{
	my( $arg ) = @_;

	sm_error( "Nested foreach" ) if defined $foreach_start;
	$foreach_start = $currpos;
	@glob = glob( $arg );
	$skip = @glob ? 0 : 1;
	$currfile = @glob ? shift @glob : "<EMPTY GLOB>";
}

sub end_if_foreach ()
{
	if( defined $foreach_start )	# end of the current foreach
	{
		if( @glob )
		{
			$currfile = shift @glob;
			$currpos = $foreach_start;
			$skip = 0;
		} else
		{
			undef $foreach_start; # fall through
		}
	} elsif( defined $if_start )	# end of the current if
	{
		undef $if_start;	# fall through
		$skip = 0;
	} else
	{
		sm_error( "'end' not in foreach or if*" );
	}
}

my %isloop = (
	foreach => \&foreach,
	end     => \&end_if_foreach
);


=head2 B<maint_setperms( $filename )>

This takes $filename, the name of a file containing a "program" written in
the "Perms" declarative language, and runs it.

Such a "program" describes desired existence/permissions/facls/ownership/
group-ownership properties of a series of files and directories.  Running
this "program" enforces those desired properties.

If the "program" contains syntax errors, we warn the user and maint_exit().

=cut

sub maint_setperms ($)
{
	my( $filename ) = @_;

	$datafilename = $filename;

	@line = read_file( $filename );
	chomp @line;

	# The State Machine itself..

	undef $foreach_start;
	undef $if_start;
	undef $currfile;
	@glob = ();
	$skip = 0;

	for( $currpos=0; $currpos < @line; $currpos++ )
	{
		my $line = $line[$currpos];
		$line =~ s/^\s+//;
		$line =~ s/\s+$//;

		# skip blank lines and comment lines
		next if $line eq '' || $line =~ /^#/;

		# every line has a command and a single arg (can be omitted)
		my( $cmd, $arg ) = split( /\s+/, $line, 2 );
		$arg //= '';

		if( $isselector{$cmd} )
		{
			if( $arg )
			{
				$currfile = $arg;
				$skip = 0;
			}
			$isselector{$cmd}->() unless $skip;
		}
		elsif( $isaction{$cmd} )
		{
			$isaction{$cmd}->( $arg ) unless $skip;
		}
		elsif( $isloop{$cmd} )
		{
			$isloop{$cmd}->( $arg );
		} else
		{
			sm_error( "Unknown line" );
		}
	}

	sm_error( "Missing end (started 'foreach' at line $foreach_start)" )
		if defined $foreach_start;

	sm_error( "Missing end (in '$if' at line $if_start)" )
		if defined $if_start;
}


1;


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

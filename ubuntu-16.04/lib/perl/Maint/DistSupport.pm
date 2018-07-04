package Maint::DistSupport;

use strict;
use warnings;

require Exporter;
our @ISA         = qw(Exporter);
our %EXPORT_TAGS = (
    'all' => [
        qw(
	      maint_distpaths
              maint_buggerme
              maint_parseproperties
	      maint_getproperties
          )
    ]
);
our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );
our @EXPORT    = qw(
);
our $VERSION = '0.01';

use Cwd;
use File::Find;
use Maint::Log qw(:all);
use Maint::HostClass qw(:all);
use Maint::SafeFile qw(:all);
use Maint::Util qw(:all);
use File::Basename;

=head1 NAME

Maint::DistSupport - handle "dist" style trees, of leaf directories
representing files that we may wish to distribute to this host, each
leaf directory containes one or more files, each named for a specific
hostclass, and containing the appropriate content of that leaf dir-file
for that hostclass.

In addition, dist trees can contain .props files throughout the hierarchy,
to set properties, and the per-hostclass filenames may also contain
property-setting suffixes.

Suppose you want to overwrite /etc/security/access.conf on all hosts
in class SERVER but you have a special case for host spock:

Your dist/ area will look like:

dist/etc/security/access.conf/SERVER
dist/etc/security/access.conf/spock

which are both files containing the appropriate access control configs.
In both cases, the contents will be used to overwrite
/etc/security/access.conf.

Note that if a host is NEITHER spock nor in the 'SERVER' hostclass, it's
/etc/security/access.conf will not be overwritten.


=head1 SYNOPSIS

    use Maint::DistSupport qw(:all);

    maint_distpaths
    maint_buggerme
    maint_parseproperties
    maint_getproperties

=head1 EXPORT

None by default, :all will export maint_buggerme().

=head1 FUNCTIONS

=cut


our %permittedprop = map { $_ => 1 }
	qw(arch mode action backup owner group);


#
# _handle_one( \@result, \%props, \%seen );
#	Internal function called by maint_distpaths():
#
#	During a File::Find traverse, handle one file or directory
#	$File::Find::name, updating @result if the file is inside a
#	directory we haven't seen before.  %props is the current
#	property hash (whenever we enter a new directory we look for a
#	.props file, and update %props) and the set %seen is used
#	(and updated) to determine whether we have seen a new directory before.
#
sub _handle_one ($$$)
{
	my( $result, $props, $seen ) = @_;

	my $path = $File::Find::name;
	$path =~ s|^\./||;

	if( $path =~ m/\.(svn|git)$/)
	{
		$File::Find::prune = 1;
		return;
	}
	if( -d $path )
	{
		print "debug: entering new dir $path\n";
		if( -f "$path/.props" )
		{
			print "debug: found $path/.props\n";
			# merge new properties into %$props
			my %newprops = maint_readhash( "$path/.props" );
			@$props{keys %newprops} = values %newprops;
		}
		return;
	}
	return unless -f $path;

	print "debug: found new file $path\n";
	my $dir = dirname( $path );
	if( ! $seen->{$dir}++ )
	{
		push @$result,
			{
				PATH  => $dir,
				PROPS => { %$props },
			};
	}
}

	
=head2 B<my @p = maint_distpaths( $base );

Finds all non-empty directories in the dist tree under $base,
and their accompanying properties, returns an array of records.
Each record is a hashref, of the form:
	{ PATH => dirname, PROPS => property_hashref }
Note that all PATHS are relative dirnames, under $base, with no "./"

=cut
sub maint_distpaths ($)
{
	my $base = shift;
	my $pwd = getcwd();

	chdir($base) || maint_fatalerror( "Cannot cd into $base");
	maint_debug( "Determining distpaths under $base");

	my @result;	# array of hashrefs
	my %seen;	# prevent duplicates
	my %props;	# properties, from the top
	find(
		sub { _handle_one( \@result, \%props, \%seen ); },
		'.' );

	chdir($pwd);

	return @result;
}


=head2 B<my %props = maint_parseproperties( $string )>

Parses $string for dotted suffix modifiers (of the form .key-value...)
and returns a property hash.

=cut

sub maint_parseproperties ($)
{
  my $string = basename($_[0]);
  maint_debug( "parseprops: string $string" );
  my @strparts = split(/\./, $string);

  shift @strparts;	# discard the filename

  my %props;
  foreach my $str (@strparts)
  {
    my( $key, $value ) = split(/[-=]/, $str, 2);
    next unless $permittedprop{$key} && defined $value;
    $props{$key} = $value;
    maint_debug( " parseprops: found prop $key, value $value" );
  }

  return %props;
}

=head2 B<my %props = maint_getproperties( $distbase, $srcpath )>

This takes $distbase, the base of the dist tree, eg. .../dist, and
$srcpath, the absolute path of a file name in the $distbase, and
figures out which properties should apply to that file by reading
.props files.

It returns a properties hash, empty if no .props files are found in
the path from $distbase to $path..

=cut

sub maint_getproperties ($$)
{
	my( $distbase, $srcpath ) = @_;

	maint_debug( "Getting properties for chosen file $srcpath" );

	my $path = $srcpath;
	$path =~ s|^$distbase/||;	# remove the distbase prefix..
	$path = dirname($path);		# remove the hostclass filename suffix
	maint_debug( "Getting properties: chosen path altered to $path" );

	-d $distbase ||
		maint_fatalerror( "getproperties: no such distbase $distbase" );

	my $dir = $distbase;
	my %props;

	foreach my $name (split(m|/|,$path) )
	{
		$dir .= "/$name";
		-d $dir ||
			maint_fatalerror( "getproperties: no such dir $dir" );
		my $pfile = "$dir/.props";
		-f $pfile || next;

		# ok, found a .props file.. read it..
		my %newprops = maint_readhash( $pfile );

		# and merge %newprops into %props
		@props{keys %newprops} = values %newprops;
	}
	# merge in any .key-value.. properties at the end of the $srcpath
	my %newprops = maint_parseproperties( $srcpath );
	@props{keys %newprops} = values %newprops;

	# sanitise: remove any unknown properties
	foreach my $k (keys %props)
	{
	    delete $props{$k} unless $permittedprop{$k};
	}

	return %props;
}


=head2 B<my( $path, $props ) = maint_buggerme( $distbase, $under )>

This takes $distbase, the base of the dist tree, eg. .../dist, and
$under, the relative path of a directory name under the $distbase,
(eg etc/security/access.conf), and searches $distbase/$under for the
most-precisely matching hostclass file, and also figures out which
properties should apply to that file.

Returns the relative path of the chosen file, of the form "$under/$hostclass",
and a hashref $props of properties that apply to that file.
Returns ( undef, undef ) on failure.

e.g. it searches for $under/hostname, $under/LAB, $under/DOC, in
the order of this host's hostclasses, all under $distbase.

=cut

sub maint_buggerme ($$)
{
    my( $distbase, $under ) = @_;
    my @classes = maint_listclasses();

    #die "debug: distbase=$distbase, under=$under\n";
    my $basedir = "$distbase/$under";
    maint_debug( "debug maint_buggerme: distbase=$distbase, under=$under, basedir=$basedir" );

    unless( -d $basedir and -r $basedir )
    {
        maint_warning( "maint_buggerme: $basedir is not a readable directory");
        return ( undef, undef );
    }
    foreach my $class (@classes)
    {
        my $classfile = "$distbase/$under/$class";
	my @g = glob("$classfile.*");
	push @g, $classfile if -f $classfile;
	maint_fatalerror( "found $classfile.* classfiles @g" ) if @g > 1;

	next if @g==0;
	my %props = maint_getproperties( $distbase, $g[0] );
	$g[0] =~ s|^$distbase/||;
	return ( $g[0], \%props );
    }
    return ( undef, undef );
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

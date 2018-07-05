package Maint::DistSupport;

use strict;
use warnings;

require Exporter;
our @ISA         = qw(Exporter);
our %EXPORT_TAGS = (
    'all' => [
        qw(
	      maint_distpaths
              maint_distchoose
              maint_parseproperties
          )
    ]
);
our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );
our @EXPORT    = qw(
);
our $VERSION = '0.01';

use Cwd;
use File::Basename;
use Data::Dumper;
use Maint::Log qw(:all);
use Maint::HostClass qw(:all);
use Maint::SafeFile qw(:all);
use Maint::Util qw(:all);

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
    maint_distchoose
    maint_parseproperties

=head1 EXPORT

None by default, :all will export all the above 3.

=head1 FUNCTIONS

=cut


our %permittedprop = map { $_ => 1 }
	qw(arch mode action backup owner group);


#
# trav_dir( $dir, \@result, \%parentprops );
#
#	traverse a dist-style $dir, looking for non-empty leaf directories
#	and their properties.  %parentprops is the property hash
#	applying to this directory.
#	Build the result in @result - a list of hash-records, each of the form:
#	{
#		PATH       => dirname,
#		PROPS      => property_hashref,
#		CLASSFILES => class_to_props_hashref
#	}
#	- PATH is the logical leaf-dir dirname, with a leading "/"
#	  (eg "/etc/security/access.conf").
#	- PROPS stores the inherited properties for this PATH,
#	- CLASSFILES (new) stores the info about all class-specific files
#	  within that PATH (directory in the dist tree),
#	  eg CLASSFILES might contain an entry mapping "HOSTDOC" to
#	    { FILE => "HOSTDOC.mode-0644" }, FPROPS => {mode => '0644'}, }
#	  (the "FILE" atttribute is omitted if FILE is the same as the
#	  hostclass name, eg "HOSTDOC")
#
#	Whenever we enter a new directory we look for an optional .props file,
#	and build a new %props hash for this directory if it's found.
#	then we grab the contents of the directory.  apart from the
#	optional .props file (and '.' and '..'), either ALL the contents
#	of $dir should be FILES or ALL should be DIRECTORIES.  die if
#	there's a mixture.
#
#	we don't actually care about what files there are, just > 0 of
#	them.  we do care about the subdirs, so we accumulate them.
#
sub trav_dir ($$$);
sub trav_dir ($$$)
{
	my( $dir, $result, $parentprops ) = @_;

	$dir =~ s|^\./||;

	#print "trav_dir: entering new dir $dir\n";
	my $propfile = "$dir/.props";
	my $myprops = $parentprops;
	if( -f $propfile )
	{
		maint_debug( "found $propfile" );
		# form a new %props hash containing the inherited
		# parental properties overlaid with the new properties
		$myprops = { %$parentprops };
		my %newprops = maint_readhash( $propfile );
		@$myprops{keys %newprops} = values %newprops;
	}

	# read the contents of $dir
        opendir(my $dh, $dir) || die;
	my @subdirs;
	my @files;
	while( readdir $dh )
	{
	    next if $_ eq '.' || $_ eq '..' || $_ eq '.props'
	    	 || $_ eq '.svn' || $_ eq '.git';

	    my $child = "$dir/$_";
	    push @subdirs, $child if -d $child;
	    push @files, $_ if -f $child;
	}
	closedir $dh;
	@subdirs = sort @subdirs;
	my $nsubdirs = @subdirs;
	my $nfiles = @files;

	#print "trav_dir: in $dir, there are $nsubdirs sub dirs ".
	#    "and $nfiles files\n";

	die "trav_dir: in $dir, there are $nsubdirs sub dirs (>0) ".
	    "and $nfiles files (>0)\n" if $nfiles && $nsubdirs;

	if( $nsubdirs )
	{
		foreach my $subdir (@subdirs)
		{
			trav_dir( $subdir, $result, $myprops );
		}
	} else
	{
		my %classes;
		foreach my $file (@files)
		{
			my( $basename, %fileprops ) =
				maint_parseproperties( $file );
			$classes{$basename} =
			{
				FPROPS => { %fileprops },
			};
			$classes{$basename}{FILE} = $file unless
				$file eq $basename;
		}
		push @$result,
			{
				PATH  => "/$dir",
				PROPS => { %$myprops },
				CLASSFILES => { %classes },
			};
	}
}


=head2 B<my @p = maint_distpaths( $base );

Finds all non-empty directories in the dist tree under $base,
and their accompanying properties, returns an array of records.
Each record is a hashref, of the form:
	{
		PATH => dirname,
		PROPS => property_hashref,
		CLASSFILES => class_to_props_hashref
	}
Note that all PATHS are logical dirnames, under $base, with a leading "/"
PROPS stores the inherited properties for this PATH,
and CLASSFILES (new) stores the info about all class-specific files
within that PATH (directory in the dist tree),
eg CLASSFILES might contain an entry mapping "HOSTDOC" to
	{ FPROPS => {mode => '0644'},  FILE => "HOSTDOC.mode-0644" }

=cut
sub maint_distpaths ($)
{
	my $base = shift;
	my $pwd = getcwd();

	chdir($base) || maint_fatalerror( "Cannot cd into $base");
	maint_debug( "Determining distpaths under $base");

	my @result;	# array of hashrefs
	trav_dir( ".", \@result, {} );
	#print Dumper \@result;

	chdir($pwd);

	return @result;
}


=head2 B<my $basename, %props ) = maint_parseproperties( $string )>

Parses $string for dotted suffix properties (of the form .key-value...)
and returns the basename of $string (without the suffix properties)
and %props, the property hash (containing the suffix properties).

=cut

sub maint_parseproperties ($)
{
	my $string = basename($_[0]);
	maint_debug( "parseprops: string $string" );

	# problems if hostclasses OR HOSTNAMES ever have '.'s in them!
	# eg. if hostnames are ever FQDNs?
	my @strparts = split(/\./, $string);

	my $basename = shift @strparts;

	my %props;
	foreach my $str (@strparts)
	{
		my( $key, $value ) = split(/[-=]/, $str, 2);
		next unless $permittedprop{$key} && defined $value;
		$props{$key} = $value;
		maint_debug( " parseprops: found prop $key, value $value" );
	}
	return( $basename, %props );
}


=head2 B<my( $path, $newprops ) = maint_distchoose( $distbase, $under, $props, $distclasses )>

This takes $distbase, the base of the dist tree, eg. .../dist,
$under, the relative path of a directory name under the $distbase,
(eg /etc/security/access.conf), $props, a property hashref, and
$distclasses, the "which class files existed in $distbase/$under" info,
and locates the most-precisely matching hostclass file that this host is in.

Returns the relative path of the chosen file, of the form "$under/$hostclass",
and a hashref $props of properties that apply to that file.
Returns ( undef, undef ) on failure.

e.g. it searches for $under/hostname, $under/LAB, $under/DOC, in
the order of this host's hostclasses, all under $distbase.

=cut

sub maint_distchoose ($$$$)
{
    my( $distbase, $under, $props, $distclasses ) = @_;
    my @classes = maint_listclasses();

    #die "debug: distbase=$distbase, under=$under\n";
    my $basedir = "$distbase$under";
    maint_debug( "distchoose: distbase=$distbase, under=$under, basedir=$basedir" );

    #maint_info( "distchoose: under=$under, distclasses=".Dumper($distclasses) );

    unless( -d $basedir and -r $basedir )
    {
        maint_warning( "distchoose: $basedir is not a readable directory");
        return ( undef, undef );
    }
    foreach my $class (@classes)
    {
	maint_fatalerror( "class <<$class>> empty, classes are <<@classes>>" ) unless defined $class && $class;
	my $fileinfo = $distclasses->{$class};
	next unless defined $fileinfo;

	my $filename = $fileinfo->{FILE} // $class;
	my $fprops   = $fileinfo->{FPROPS};
	#maint_warning( "distchoose: class=$class, filename=$filename, fprops=".Dumper($fprops) );

	my $resultfilename = "$under/$filename";
	my $myprops = { %$props };
	@$myprops{keys %$fprops} = values %$fprops;

	# sanitise: remove any unknown properties
	foreach my $k (keys %$myprops)
	{
	    delete $myprops->{$k} unless $permittedprop{$k};
	}

	return ( $resultfilename, $myprops );
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

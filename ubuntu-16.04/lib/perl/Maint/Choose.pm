package Maint::Choose;

use strict;
use warnings;

require Exporter;
our @ISA         = qw(Exporter);
our %EXPORT_TAGS = (
    'all' => [
        qw(
              maint_choose
	      maint_getproperties
          )
    ]
);
our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );
our @EXPORT    = qw(
);
our $VERSION = '0.01';

#use Cwd;
use Maint::Log qw(:all);
use Maint::HostClass qw(:all);
use Maint::SafeFile qw(:all);
use Maint::Util qw(:all);
use File::Basename;

=head1 NAME

Maint::Choose - choose the most hostclass-specific file in a tree, and
read the properties that apply to that file.

=head1 SYNOPSIS

    use Maint::Choose qw(:all);

    maint_choose
    maint_getproperties

=head1 EXPORT

None by default, :all will export maint_choose().

=head1 FUNCTIONS

=cut

sub _make_choice(@)
{
    my @orderedfiles = @_;

    # We want to find the first populated member of this list of lists.
    # It also needs to be a singleton.
    foreach my $olist (@orderedfiles)
    {
	next unless defined $olist;
	if( @$olist > 1 )
	{
	    my $ostr = join(", ", @$olist);
	    maint_warning( "$ostr are of equal priority, cannot reconcile!");
	    return undef;
	}
	# precisely one candidate, good!
	my $candidate = $$olist[0];
	if( -f $candidate && -r $candidate )
	{
	    maint_debug( "Matched file: $candidate" );
	    return $candidate;
	}
        maint_warning( "$candidate would match but is not readable!");
        return undef;
    }
    return undef;
}


=head2 B<my %props = maint_getproperties( $distbase, $path )>

This takes $distbase, the base of the dist tree, eg. .../dist, and
$path, the absolute path of a file name in the $distbase, and
figures out which properties should apply to that file by reading
.props files.

It returns a properties hash, empty if no .props files are found in
the path from $distbase to $path..

=cut

sub maint_getproperties ($$)
{
	my( $distbase, $path ) = @_;

	$path =~ s|^$distbase/||;	# remove the distbase prefix..
	$path = dirname($path);		# remove the hostclass filename suffix

	maint_info( "Getting properties for chosen file $path under $distbase" );
	-d $distbase ||
		maint_fatalerror( "getproperties: no such distbase $distbase" );

	my $dir = $distbase;
	my %props;
	my @above;

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

	return %props;
}


=head2 B<my( $path, $props ) = maint_choose( $distbase, $basedir )>

This takes $distbase, the base of the dist tree, eg. .../dist, and
$basedir, the absolute path of a directory name in the $distbase,
(eg .../dist/etc/security/access.conf), and searches $basedir for the
most-precisely matching hostclass file, and also figures out which
properties should apply to that file.

Returns a fully-qualified path to the chosen file, and a hashref $props
of properties that apply to that file.  Returns ( undef, undef ) on failure.

e.g. it searches for $basedir/hostname, $basedir/LAB, $basedir/DOC, in
the order of this host's hostclasses.

=cut

sub maint_choose ($$)
{
    my( $distbase, $basedir ) = @_;
    my @classes = maint_listclasses();

    #die "debug: distbase=$distbase, basedir=$basedir\n";
    maint_debug( "debug maint_choose: distbase=$distbase, basedir=$basedir" );

    unless( -d $basedir and -r $basedir )
    {
        maint_warning( "maint_choose: $basedir is not a readable directory");
        return ( undef, undef );
    }
    foreach my $class (@classes)
    {
        my $classfile = maint_mkpath($basedir,$class);
	my @classfiles = glob("$classfile.*");
	push @classfiles, $classfile if -f $classfile;
	my $n = @classfiles;

	if( $n > 1 )
	{
		maint_warning( "maint_choose: $n files match $classfile, skipping" );
		next;
	}

	if( $n == 1 )
	{
		my $result = $classfiles[0];
		my %props = maint_getproperties( $distbase, $result );
		return ( $result, \%props );
	}
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

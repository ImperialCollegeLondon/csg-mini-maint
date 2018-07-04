package Maint::Choose;

use strict;
use warnings;

require Exporter;
our @ISA         = qw(Exporter);
our %EXPORT_TAGS = (
    'all' => [
        qw(
              maint_choose
              maint_parseproperties
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
    maint_parseproperties
    maint_getproperties

=head1 EXPORT

None by default, :all will export maint_choose().

=head1 FUNCTIONS

=cut


=head2 B<my %props = maint_parseproperties( $string )>

Parses $string for dotted suffix modifiers (of the form .key-value...)
and returns a property hash.

=cut

sub maint_parseproperties ($)
{
  my $string = basename($_[0]);
  my @strparts = split(/\./, $string);

  shift @strparts;	# discard the filename

  my %props;
  foreach my $mod (@strparts)
  {
    my( $key, $value ) = split(/\-/, $mod, 2);
    $props{$key} = $value if defined $value;
  }

  return %props;
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

	maint_debug( "Getting properties for chosen file $path" );

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
	# find any properties at the end of the $path, in .key-value... form
	my %newprops = maint_parseproperties( $path );
	# and merge them into %props
	@props{keys %newprops} = values %newprops;

	return %props;
}


=head2 B<my( $path, $props ) = maint_choose( $distbase, $under )>

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

sub maint_choose ($$)
{
    my( $distbase, $under ) = @_;
    my @classes = maint_listclasses();

    #die "debug: distbase=$distbase, under=$under\n";
    my $basedir = "$distbase/$under";
    maint_debug( "debug maint_choose: distbase=$distbase, under=$under, basedir=$basedir" );

    unless( -d $basedir and -r $basedir )
    {
        maint_warning( "maint_choose: $basedir is not a readable directory");
        return ( undef, undef );
    }
    foreach my $class (@classes)
    {
        my $classfile = "$distbase/$under/$class";
	my @g = glob("$classfile.*");
	push @g, $classfile if -f $classfile;
	maint_fatalerror( "found $classfile.* classfiles @g" )
		if @g > 1;

	next unless @g==1;
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

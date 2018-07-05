package Maint::Choose;

use strict;
use warnings;

require Exporter;
our @ISA         = qw(Exporter);
our %EXPORT_TAGS = (
    'all' => [
        qw(
              maint_choose
          )
    ]
);
our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );
our @EXPORT    = qw(
);
our $VERSION = '0.01';

use Maint::Log qw(:all);
use Maint::HostClass qw(:all);

=head1 NAME

Maint::Choose - choose the most hostclass-specific file in a tree.

=head1 SYNOPSIS

    use Maint::Choose qw(:all);

    maint_choose

=head1 EXPORT

None by default, :all will export maint_choose().

=head1 FUNCTIONS

=cut


=head2 B<my $path = maint_choose( $choicedir )>

This takes $choicedir, a leaf-directory that contains no subdirectories,
but which contains one or more files named for hostclasses, and searches
$choicedir for the most-precisely matching hostclass file given the
hostclasses this host is in.

Returns the path of the chosen file, of the form "$choicedir/$hostclass".
Returns undef on failure.

e.g. it searches for $choicedir/hostname, $choicedir/LAB, $choicedir/DOC, in
the order of this host's hostclasses.

=cut

sub maint_choose ($)
{
    my( $choicedir ) = @_;
    my @classes = maint_listclasses();

    maint_debug( "debug maint_choose: choicedir=$choicedir" );

    unless( -d $choicedir and -r $choicedir )
    {
        maint_warning( "maint_choose: $choicedir is not a readable directory");
        return undef;
    }
    foreach my $class (@classes)
    {
        my $classfile = "$choicedir/$class";
	next unless -f $classfile;
	return $classfile;
    }
    return undef;
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

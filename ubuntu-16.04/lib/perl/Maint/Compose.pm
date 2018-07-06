package Maint::Compose;

use strict;
use warnings;

require Exporter;
our @ISA         = qw(Exporter);
our %EXPORT_TAGS = (
    'all' => [
        qw(
	      maint_compose
          )
    ]
);
our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );
our @EXPORT    = qw(
);
our $VERSION = '0.01';

use Cwd;
use Maint::Log qw(:all);
use Maint::HostClass qw(:all);

=head1 NAME

Maint::Compose - hostclass-file config file composer for Maint

=head1 SYNOPSIS

    use Maint::Compose qw(:all);

    maint_compose

=head1 EXPORT

None by default, :all will export the above.

=head1 FUNCTIONS

=cut


=head2 B<my @lines = maint_compose( $directory )>

This will return an array of all lines of the composition of matching
class files, most generic hostclass files first, most specific last.

It returns undef on failure.

=cut

sub maint_compose ($)
{
	my $basedir = shift;

	my $cwd = getcwd();
	print "compose: cwd=$cwd\n";

	# Now we gather together all lines from files like:
	# MOST_GENERAL_HOSTCLASS
	#    LESS_GENERAL_HOSTCLASS
	#	...
	#          hostname
	#

	my @classes = reverse maint_listclasses();

	my @lines;
	foreach my $class (@classes)
	{
		my $filename = "$basedir/$class";
		next unless -f $filename;

		if( open( my $infh, '<' . $filename ) )
		{
			#maint_debug( "maint_compose: $filename");
			my @l = <$infh>;
			close( $infh );
			chomp @l;
			push @lines, @l;
		} else
		{
			maint_warning( "Can't read $filename");
		}
	}
	return @lines;
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

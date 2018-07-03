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

#use Cwd;
use Maint::Log qw(:all);
use Maint::HostClass qw(:all);
use Maint::SafeFile qw(:all);
use Maint::Util qw(:all);
#use File::Spec;

=head1 NAME

Maint::Choose - choose the most hostclass-specific file in a tree

=head1 SYNOPSIS

    use Maint::Choose qw(:all);

    maint_choose

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


=head2 B<my $path = maint_choose( $basedir )>

This takes a directory name and searches that directory for the
best-matching file using the standard class-modifier naming scheme,
returning a fully-qualified path to that file.

e.g. it searches for $dir/hostname, $dir/LAB, $dir/DOC, ...

It returns undef on failure or the filename with full path

=cut

sub maint_choose ($)
{
    my $basedir = shift;
    my @classes = maint_listclasses();
    unless( -d $basedir and -r $basedir )
    {
        maint_warning( "maint_choose: $basedir is not a readable directory");
        return undef;
    }
    foreach my $class (@classes)
    {
        my $classfile = maint_mkpath($basedir,$class);
	my @classfiles = glob("$classfile.*");
	push @classfiles, $classfile if -f $classfile;

	# We do NOT want files with a 'comb' tag.
	
	my @orderedfiles = maint_ordermods(
		               maint_locatemods(\@classfiles,
			                        sub {!exists($_->{'comb'})}
						)
					  );
	my $result = _make_choice(@orderedfiles);
	return $result if defined $result;
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

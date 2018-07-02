package Maint::ConfigInfo;

use strict;
use warnings;

require Exporter;
our @ISA         = qw(Exporter);
our %EXPORT_TAGS = (
    'all' => [
        qw(
            maint_setconfig
	    maint_getconfigdir
	    maint_getconfig
          )
    ]
);
our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );
our @EXPORT    = qw(
);
our $VERSION = '0.01';


our $configdir;		# the directory where all config data is stored
our %configdata;	# basic config data already read (eg from
			# $configdir/info)

=head1 NAME

Maint::ConfigInfo - configuration information store for Maint scripts

=head1 SYNOPSIS

	maint_setconfig
	maint_getconfigdir
	maint_getconfig

=head1 EXPORT

None by default, :all will export:

maint_setconfig
maint_getconfigdir
maint_getconfig

=head1 FUNCTIONS

=cut

=head2 B<maint_setconfig( $confdir, $hashref );

Takes a Configuration Data directory $confdir, and a hashref $hashref
of basic configuration data that we've already read from $confdir/info,
and store it here, so that other bits of the maint libraries can read it..

=cut

sub maint_setconfig
{
    my( $confdir, $hashref ) = @_;
    %configdata = %$hashref;
    $configdir = $confdir;
}


=head2 B<my $confdir = maint_getconfigdir();>

Retrieve the configuration directory from store.

=cut

sub maint_getconfigdir
{
    return $configdir;
}


=head2 B<my $conf = maint_getconfig( $name );>

Retrieve the value of a specific configuration key name $name from store.

=cut

sub maint_getconfig
{
    my( $name ) = @_;
    return $configdata{$name};
}


1;

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

package Maint::ReadCSV;

use strict;
use warnings;

require Exporter;
our @ISA         = qw(Exporter);
our %EXPORT_TAGS = (
    'all' => [
        qw(
            maint_readcsv
          )
    ]
);
our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );
our @EXPORT    = qw(
);
our $VERSION = '0.02';

use Text::CSV;

use Maint::Log qw(:all);
#use Maint::DB qw(:all);
use Maint::SafeFile qw(:all);
use Maint::Util qw(:all);
use Maint::ConfigInfo qw(:all);

=head1 NAME

Maint::ReadCSV - utility module to support reading CSV files with a header line

=head1 SYNOPSIS

    use Maint::ReadCSV qw(:all);
    
    maint_readcsv

=head1 EXPORT

None by default, :all will export all symbols listed above.

=head1 DESCRIPTION

This module deals with reading CSV files with a header line that
defines the fields. Only one function:


=head1 FUNCTIONS

=cut

=head2 B<my @list = maint_readcsv( $filename )>

Reads the named CSV file $filename, where the first line is a comma
separated list of column names, and the rest of the file are comma
separated records.

Each line is turned into a hashref mapping column name -> volumn value,
and an array of all such hashrefs is returned.  Comment lines (starting
with '#') and blank lines are silently ignored.

=cut

sub maint_readcsv
{
    my( $filename ) = @_;

    open( my $infh, '<', $filename ) ||
        maint_fatalerror( "Can't open csv file $filename");

    my $csv = Text::CSV->new ( { binary => 1 } ) ||
    	maint_fatalerror( "Cannot use CSV: ".Text::CSV->error_diag () );

    my $titles = $csv->getline( $infh );

    my @result;
    while( <$infh> )
    {
	chomp;
	next if /^#/;
	$csv->parse( $_ );
	my @row = $csv->fields();
	my $hashref = {};
	foreach my $pos (0..$#row)
	{
		$hashref->{ $titles->[$pos] } = $row[$pos];
	}
	push @result, $hashref;
    }

    return @result; 
}


1;


=head1 AUTHORS

Duncan White E<lt>dcw@imperial.ac.ukE<gt>,
Lloyd Kamara E<lt>ldk@imperial.ac.ukE<gt>,

=head1 COPYRIGHT AND LICENSE

Copyright 2003-2018 Department of Computing, Imperial College London

=cut

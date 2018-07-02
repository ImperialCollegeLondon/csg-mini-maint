package Maint::ScriptArgs;
use strict;
use warnings;
require Exporter;
our @ISA         = qw(Exporter);
our %EXPORT_TAGS = (
	'all' => [
		qw(
		  maint_initarg
		  maint_getattr
		  maint_testmode
		  maint_pushargs
		  maint_usage
		  )
	]
);
our @EXPORT_OK = (@{ $EXPORT_TAGS{'all'} });
our @EXPORT    = qw(
);
our $VERSION = '0.01';
use Getopt::Long qw(:config gnu_getopt pass_through);

=head1 NAME

Maint::ScriptArgs - script argument processing for scripts based on Maint

=head1 SYNOPSIS

    maint_initarg
    maint_getattr
    maint_testmode
    maint_pushargs
    maint_usage

=head1 EXPORT

None by default, :all will export all of the above.

=head1 FUNCTIONS

=cut

our %args = ();

sub maint_usage
{
	print << "END";
Options to maint scripts:
    --[no]debug        - Print extra information
    --[no]dryrun       - Don't really do stuff, just go through the motions
    --[no]silent       - Don't print anything but warnings and errors
    --[no]logperline   - Display log message one per line (default no)
    --[no]colour       - Display log message with colour (default yes)
    --[no]machineread  - Makes logs machine readable
    --list             - Display all scriptnames and exit
    --mode=boot
         cron-15
         cron-30
         cron-60
	 cron-0300hrs
	 cron-0400hrs
         install
         manual        - Set the run "mode"
    --trace=none|caller|stack
                       - sets trace mode
END
	exit 0;
}

=head2 B<maint_initarg()>

This processes the command line arguments (such as --debug etc)

Args are taken from @ARGV. Unrecognised options are left in @ARGV.

Returns: none - errors in the @ARGV arguments will exit with a usage() message.

The options which it recognises are:

	--[no]debug        - Print extra information
	--[no]dryrun       - Don't really do stuff, just go through the motions
	--[no]silent       - Don't print anything but warnings and errors
        --[no]logperline   - Display log message one per line (default no)
        --[no]colour       - Display log message with colour (default yes)
        --[no]machineread  - Makes logs machine readable
    	--trace=none|caller|stack - sets trace mode
	--mode=boot|install|manual|cron - Set the `time' for the script (defaults to manual)
        --hostname         - Run this script as if on host hostname
	--list             - Display all scriptnames

=cut

sub maint_initarg ()
{
	my $classes_done = 0;

	# (re-) init the package globals
	%args = (
		debug       => 0,
		list        => 0,
		dryrun      => 0,
		silent      => 0,
		logperline  => 0,
		colour      => 1,
		machineread => 0,
		trace       => 'none',
		hostname    => undef,
		mode        => 'manual',
		help        => 0,
	);
	maint_usage() unless
		GetOptions(
			\%args,
			'debug!',
			'list!',
			'dryrun!',
			'silent!',
			'logperline!',
			'colour!',
			'machineread!',
			'trace:s',
			'mode:s',
			'hostname:s',
			'help|usage',
		);
	maint_usage() if $args{help};
	# Force dryrun if we are faking the hostname
	$args{dryrun} = 1 if $args{hostname};
	return 1;
}

=head2 B<maint_getattr(string:attribute)>

Return an attribute of the current script's running environment.

Valid attributes are: mode, logperline, colour, machineread,
debug, dryrun, silent, hostname, list

=cut

sub maint_getattr($)
{
	my ($attr) = @_;
	return $args{$attr};
}

=head2 B<maint_testmode(string:mode)>

Test whether the script is running in a given mode. Functionally
identical to:

return (maint_getattr('mode') eq $mode);

Valid modes are: install, boot, manual, cron

=cut

sub maint_testmode($)
{
	my ($mode) = @_;
	return ($args{mode} eq $mode);
}

=head2 B<maint_pushargs()>

Push the parsed arguments back onto @ARGV in the same form

=cut

sub maint_pushargs ()
{
	if ($args{list}) { push @ARGV, '--list'; }
	if ($args{debug}) { push @ARGV, '--debug'; }
	else { push @ARGV, '--nodebug'; }
	if ($args{silent}) { push @ARGV, '--silent'; }
	else { push @ARGV, '--nosilent'; }
	if ($args{dryrun}) { push @ARGV, '--dryrun'; }
	else { push @ARGV, '--nodryrun'; }
	if ($args{logperline}) { push @ARGV, '--logperline'; }
	else { push @ARGV, '--nologperline'; }
	if ($args{colour}) { push @ARGV, '--colour'; }
	else { push @ARGV, '--nocolour'; }
	if ($args{machineread}) { push @ARGV, '--machineread'; }
	else { push @ARGV, '--nomachineread'; }
	if ($args{trace}) { push @ARGV, '--trace=' . $args{trace}; }
	else { push @ARGV, '--trace=none'; }
	push @ARGV, '--mode=' . $args{mode};
	push @ARGV, '--hostname=' . $args{hostname} if defined $args{hostname};
}
1;

=head1 AUTHORS

Duncan White E<lt>dcw@doc.ic.ac.ukE<gt>, 
Matt Johnosn E<lt>mwj@doc.ic.ac.ukE<gt>, 
Adam Langley E<lt>agl@imperialviolet.orgE<gt>, 
Tim Southerwood E<lt>ts@dionic.netE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2003-2018 Department of Computing, Imperial College London

=cut

__END__

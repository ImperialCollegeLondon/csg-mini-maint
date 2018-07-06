package Maint::Run;

use strict;
use warnings;

require Exporter;
our @ISA         = qw(Exporter);
our %EXPORT_TAGS = (
    'all' => [
        qw(
	    maint_runcmd
	    maint_runcmd1
          )
    ]
);
our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );
our @EXPORT    = qw(
);
our $VERSION = '0.01';

use IPC::Run;
use IPC::Run3;
use Maint::Log qw(:all);
use Maint::Util qw(:all);

=head1 NAME

Maint::Run - IPC::Run for scripts based on Maint

=head1 SYNOPSIS

    maint_runcmd
    maint_runcmd1

=head1 EXPORT

None by default, :all will export both.

=head1 FUNCTIONS

=cut

=head2 B<my $exitcode = maint_runcmd( $cmd_arrayref [, $override_dry_run [, $errlevel [, $stdin [, $stdout [, $stderr ]]]]])>

Replacement for maint_system(). Uses IPC:Run3.

Runs the command, unless --dryrun is in force.
On non-zero exit from the command, will log at the given error level,
and thus possibly die.  stdin, stdout, stderr supplied optionally in
any of the forms supported by IPC::Run3::run3()

May be abbreviated to maint_runcmd(arrayref:command) to meet most common needs.

See caveats below.
 
Parameters:

  command:
     Array ref of command components, eg: [qw(mount -a)]

  override_dry_run: 
     Allow the command to run even if --dryrun is in force.
     Useful for query commands with no side effects.
     Undef is assumed false.

  errlevel:
     Maint::Log::(LOG_ERR|LOG_WARNING|LOG_INFO|LOG_DEBUG): log
     level to issue if the run command exits with a non zero code or
     the command cannot be run.  Defaults to LOG_ERR which is fatal.

  stdin:
     As per IPC::Run3::run3() except that undef is cast to \undef -
     we never want the parent code's stdin used.

  stdout:
     As per IPC::Run3::run3() except that undef is cast to \undef -
     we never want the parent code's stdout used.

  stderr:
     As per IPC::Run3::run3() except that undef is cast to \undef -
     we never want the parent code's stderr used. On command error,
     stderr will be output via a maint_log() message provided that
     stderr has not been supplied as a defined parameter. perror()
     of last system call will be pronted too.

When errlevel is not the fatal LOG_ERR, it returns the actual exit value
of the program run, 0 for success or -1 if --dryrun
prevented the command from running.

=cut

sub maint_runcmd ($;$$$$$)
{
    my( $cmd, $overridedryrun, $errlevel, $stdin, $stdout, $stderr ) = @_;
    
    maint_fatalerror( "cmd is not an array ref") unless ref $cmd eq 'ARRAY';
    my $cmdstring = join ' ', @$cmd;

    $overridedryrun = 0 unless defined $overridedryrun;

    # What we will treat errors as.  Taken from Maint::Log.pm, the
    # available values are: LOG_ERR (die), LOG_WARNING (warn and continue)
    # LOG_INFO (info and continue) LOG_DEBUG (debug and continue)
    # For compatability $errlevel=undef => LOG_ERR and $errlevel=1 => LOG_DEBUG
    if( !defined $errlevel || $errlevel == 0 )
    {
	    $errlevel = LOG_ERR;
    }
    elsif( $errlevel == 1 )
    {
	    $errlevel = LOG_WARNING;
    }
    # Force decoupling of caller's std* handles:
    my $localstderr = '';
    $stdin = \undef unless defined $stdin;
    $stdout = \undef unless defined $stdout;
    $stderr = \$localstderr unless defined $stderr;
    
    if( !$overridedryrun && maint_dryrun() )
    {
	maint_debug( "Not running: $cmdstring");
	return -1;
    } else 
    {
	maint_debug( "Running: $cmdstring");
	# mwj -- turn off die redirection for IPC::Run3
	my $diehldr = $SIG{__DIE__};
	$SIG{__DIE__} = 'DEFAULT';
	my $ret = run3($cmd, $stdin, $stdout, $stderr);
	$SIG{__DIE__} = $diehldr;
	my $cmdexit = $? >> 8;
	if( !$ret || $cmdexit != 0 )
	{
		my $perr = $!;
		maint_log($errlevel, "maint_runcmd() failed: $cmdstring: exit=$cmdexit, perror=[$perr], cmd stderr=$localstderr");
	}
	return $cmdexit;
    }
}


=head2 B<my $exit = maint_runcmd1( $command [, $override_dry_run [, $errok [, stdin [, stdout [, stderr ]]]]])>

Replacement for maint_system(). Uses IPC:Run for instant feedback from
stderr, stdout

Runs the command, unless --dryrun is in force. On non-zero exit from
the command, will force maint_log(LOG_ERR, ...) unless errok is set,
and thus die.  stdin, stdout, stderr supplied optionally in any of the
forms supported by IPC::Run3::run3()

May be abbreviated to maint_runcmd( $command ) to meet most common needs.

See caveats below.
 
Parameters:

command: Array ref of command components, eg: [qw(mount -a)]

override_dry_run: Allow the command to run even if --dryrun is in force.
	Useful for query commands with no side effects. Undef is assumed false.

errlevel:
	Maint::Log::(LOG_ERR|LOG_WARNING|LOG_INFO|LOG_DEBUG): log level to
	issue if the run command exits with a non zero code or the command
	cannot be run

stdin:
	As per IPC::Run3::run3() except that undef is cast to \undef - we
	never want the parent code's stdin used.

stdout:
	As per IPC::Run3::run3() except that undef is cast to \undef - we
	never want the parent code's stdout used.

stderr:
	As per IPC::Run3::run3() except that undef is cast to \undef - we
	never want the parent code's stderr used. On command error, stderr
	will be output via a maint_log() message provided that stderr has not
	been supplied as a defined parameter. perror() of last system call
	will be printed too.

Returns the actual exit value of the program run, 0 on success or -1 if
--dryrun prevented the command from running.  Unless errok is in force,
it is not required to check the return code as the caller program will
die on error.

=cut

sub maint_runcmd1 ($;$$$$$)
{
    my( $cmd, $overridedryrun, $errlevel, $stdin, $stdout, $stderr ) = @_;
    
    maint_fatalerror( "cmd is not an array ref") unless ref $cmd eq 'ARRAY';

    my $cmdstring = join ' ', @$cmd;
    # Explicit to be clear:
    $overridedryrun = 0 unless defined $overridedryrun;

    # What we will treat errors as (from Maint::Log.pm,
    # avail values are: LOG_ERR (die), LOG_WARN (warn and continue)
    # LOG_INFO (info and continue) LOG_DEBUG (debug and continue)
    # For compatability $errlevel=undef => LOG_ERR and $errlevel=1 => LOG_DEBUG
    $errlevel = LOG_ERR if !defined $errlevel || $errlevel == 0;
    $errlevel = LOG_WARNING if $errlevel == 1;

    # Force decoupling of caller's std* handles:
    my $localstderr = '';
    $stdin = \undef unless defined $stdin;
    $stdout = sub {} unless defined $stdout;
    $stderr = \$localstderr unless defined $stderr;
    $stdout = undef if $stdout eq '>&1';
    
    if( !$overridedryrun && maint_dryrun() )
    {
	maint_debug( "Not running: $cmdstring");
	return -1;
    }
    maint_debug( "Running: $cmdstring");
    my $ret = IPC::Run::run($cmd, $stdin, $stdout, $stderr, debug=>0);
    my $cmdexit = $? >> 8;

    if( !$ret || $cmdexit != 0 )
    {
	my $perr = $!;
	maint_log($errlevel, "maint_runcmd1() failed: $cmdstring: exit=$cmdexit, perror=[$perr], cmd stderr=$localstderr");
    }
    return $cmdexit;
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

package Maint::Log;
use strict;
use warnings;
require Exporter;
our @ISA         = qw(Exporter);
our %EXPORT_TAGS = (
	'all' => [
		qw(
		  maint_initlog
		  maint_log
		  maint_loglevel
		  maint_logperline
		  maint_isexitforced
		  maint_colouriselog
		  maint_parsablelog
		  maint_tracemode
		  maint_lognewline
		  maint_closelog
		  LOG_QUIET
		  LOG_ERR
		  LOG_WARNING
		  LOG_INFO
		  LOG_DEBUG
		  )
	]
);
our @EXPORT_OK = (@{ $EXPORT_TAGS{'all'} });
our @EXPORT    = qw(
);
our $VERSION = '0.01';

=head1 NAME

Maint::Log - provide logging for scripts based on Maint

=head1 SYNOPSIS

    use Maint::Log qw(:all);
    maint_initlog
    maint_log
    maint_loglevel
    maint_logperline
    maint_closelog
    maint_colouriselog
    maint_parsablelog
    maint_tracemode
    maint_lognewline

=head2 Loglevel constants:

    Maint::Log::LOG_DEBUG            # Show all messages
    Maint::Log::LOG_INFO             # log_info and more severe
    Maint::Log::LOG_WARNING          # etc...
    Maint::Log::LOG_ERR
    Maint::Log::LOG_QUIET            # Pseudonym for LOG_ERR (may change)

=head1 EXPORT

None by default, :all will export:

maint_initlog
maint_log
maint_loglevel 
maint_logperline
maint_colouriselog
maint_parsablelog
maint_tracemode
maint_lognewline
maint_closelog

=head1 FUNCTIONS

=cut

use Unix::Syslog;
#DCWuse IO::Handle;
use Carp;
STDOUT->autoflush(1);
STDERR->autoflush(1);

# Constants - must be in numeric order by severity
use constant {
	LOG_QUIET      => 0,                            # No logging at all
	                                                # (except for errors which are fatal)
	LOG_ERR        => Unix::Syslog::LOG_ERR,        # Only errors (log_error)
	LOG_WARNING    => Unix::Syslog::LOG_WARNING,    # Warnings + errors (maint_log(LOG_WARNING, , log_error)
	LOG_INFO       => Unix::Syslog::LOG_INFO,       # Above + log_info
	LOG_DEBUG      => Unix::Syslog::LOG_DEBUG,      # Very verbose (log everything)
};
our %logstr = (
	LOG_ERR      => 'ERROR',
	LOG_WARNING  => 'WARNING',
	LOG_INFO     => 'INFO',
	LOG_DEBUG    => 'DEBUG',
);
our %logcolours = (
	LOG_ERR      => "\x1b[0;1;37;41m",
	LOG_WARNING  => "\x1b[0;1;40;33m",
	LOG_INFO     => "\x1b[0;1;32m",
	LOG_DEBUG    => "\x1b[0;1;34m",
);
our %loglevels = (
	LOG_ERR      => 'err',
	LOG_WARNING  => 'warning', 
	LOG_INFO     => 'notice',
	LOG_DEBUG    => 'debug',
);
our $loglevel        = LOG_INFO;
our $lsyslogok       = 1;
our $scriptname      = '';
our $log_exit_forced = 0;
our $logperline      = 0;
our $colourise       = 1;
our $machineread     = 0;
our $tracemode       = '';
our $colournormal    = "\x1b[0m";
our $underline       = "\x1b[4m";

# Internal wrapper around Unix::Syslog::syslog
sub _lsyslog
{
	my ($level, $msg) = @_;
	$msg =~ s/%/%%/g;	# DCW was \%
	Unix::Syslog::syslog($level, $msg);
}

# warn handler
sub _warn
{
	maint_log(LOG_WARNING, "unhandled warn(): " . join ' ', @_);
	return 1;
}

# die handler
sub _die
{
	maint_log(LOG_ERR, "unhandled die(): " . join ' ', @_);
	return 1;
}


=head2 B<maint_initlog( $scriptname [, $loglevel = Maint::Log::LOG_INFO])>

Initialise the log, noting the log prefix (scriptname) and optionally set the
log level to only show messages at or above the indicated priority.

Note: Regardless of the level set, all messages of LOG_INFO or higher will go
out via syslog. If LOG_DEBUG is set, then debug messages will also go to syslog.

=cut

sub maint_initlog ($;$)
{
	($scriptname, my $ploglevel) = @_;
	maint_loglevel($ploglevel) if defined $ploglevel;

	# Now set up local logging via /dev/log
	Unix::Syslog::openlog(
		"Maint/$scriptname",
		Unix::Syslog::LOG_PID,
		Unix::Syslog::LOG_LOCAL5
	);
	maint_lognewline();
	_log_startend("Starting: $scriptname");
	maint_lognewline();

	# Now add a die() and warn() handler just in case
	$SIG{__WARN__} = \&_warn;
	$SIG{__DIE__}  = \&_die;
}


=head2 B<maint_closelog()>

Must be called at the end of your code - prints a confirmation message that
all finished well.

=cut

sub maint_closelog ()
{
	maint_lognewline();
	_log_startend("Finished: $scriptname");
	maint_lognewline();
}


=head2 B<maint_loglevel( $loglevel )>
=head2 B<OR my $loglevel = maint_loglevel()>

Returns current loglevel. If parameter supplied, sets the new loglevel to that.

=cut

sub maint_loglevel
{
	my $p = shift;
	return $loglevel unless defined $p;
	unless( $p >= 0 && $p <= LOG_DEBUG )
	{
		$loglevel = LOG_INFO;
		maint_log(LOG_ERR, "maint_loglevel() - invalid level [$p]");
		return $loglevel;
	}
	$loglevel = $p;
	return $loglevel;
}


=head2 B<maint_logperline( $logperline )>
=head2 B<OR my $logperline = maint_logperline()>

Returns current logperline. If parameter supplied, sets the new logperline
to that.

If set, then each log message is terminated with a newline.

=cut

sub maint_logperline
{
	my $p = shift;
	$logperline = $p if defined $p;
	return $logperline;
}


=head2 B<maint_colouriselog( $colourise )>
=head2 B<OR my $colourise = maint_colouriselog()>

Returns current colourise. If parameter supplied, sets the new colourise
to that.

If set, then each log message will have ANSI colour escapes embedded.

If unset, each log message will be prefixed with DEBUG:, INFO:, WARN:
or ERROR:

=cut

sub maint_colouriselog
{
	my $p = shift;
	$colourise = $p if defined $p;
	return $colourise;
}


=head2 B<maint_parsablelog( $machineread )>
=head2 B<OR my $machineread = maint_parsablelog()>

Returns current machineread. If parameter supplied, sets the new
machineread to that.

If set, then each log message will be set to no colour, one per line
and be of the form:

DEBUG:Log message
INFO:Log message
WARN:Log message
ERROR:Log Message

=cut

sub maint_parsablelog
{
	my $p = shift;
	$machineread = $p if defined $p;
	return $machineread;
}


=head2 B<maint_tracemode( $tracemode )>
=head2 B<OR my $tracemode = maint_tracemode()>

Returns current trace mode. If parameter supplied, sets the new trace
mode to that.

If 'none', then each log message will be bare.
If 'caller', then each log message printed will include a caller reference.
If 'stack', then each log message printed will include a stacktrace.

=cut

sub maint_tracemode
{
	my $p = shift;
	if( defined $p )
	{
		if     ( $p eq 'none' )   {$tracemode='';}
		elsif  ( $p eq 'caller' ) {$tracemode='c';}
		elsif  ( $p eq 'stack' )  {$tracemode='s';}
		else   { maint_log(LOG_ERR, "Illegal tracemode, [$p]"); }
	}
	return $tracemode;
}


=head2 B<maint_isexitforced( $log_exit_forced )>
=head2 B<OR my $isforced = maint_isexitforced()>

Intended only for the END handler in Maint.pm - will set this flag if log_error
signalled an exit so that Maint.pm's END handler won't whine.

=cut

sub maint_isexitforced
{
	my $p = shift;
	$log_exit_forced = $p if $p;
	return $log_exit_forced;
}


sub _log_startend ($)
{
	my $line = shift;
	print _formatforscreen(LOG_INFO, $line) unless
		maint_loglevel() < LOG_INFO;
	$line =~ s/%/\%/g;
	_lsyslog(LOG_INFO, $line) if $lsyslogok;
}


=head2 B<maint_log( $level, $message )>

Generate a log entry to STDERR and syslog at the level specified.

=cut

sub maint_log ($$)
{
	my ($level, $line) = @_;

	# If this is a debug message, don't bother even syslogging it
	# unless the loglevel has been set to nuclear levels!
	if ($level == LOG_DEBUG)
	{
		return 1 unless maint_loglevel() >= LOG_DEBUG;
	}
	
	if( $tracemode eq 's' )
	{
		my $context = Carp::longmess();
		$context =~ s/\n+$//;
		$context =~ s/^\s+at\s+//;
		$context =~ s/[\n\t]+/}{/g;
		$line .= ' TRACE{' . $context;
		$line .= '}';
	}
	elsif( $tracemode eq 'c' || $level == LOG_DEBUG || $level == LOG_ERR )
	{
		my( undef, $filename, $lineno, undef ) = caller(0);
		my( undef, undef, undef, $subroutine ) = caller(1);
		$subroutine = 'Sub???' unless defined $subroutine;
		my( $sub ) = ($subroutine =~ m/([^:]+)$/);
		my( $file ) = ($filename =~ m#^(?:\.\./)*(?:lib/perl/)?(.*)$#);
		$file='?' unless defined $file;
		$line = "{$sub():$file:$lineno} " . $line;
	}
	
	# Perform the syslogging.
	_lsyslog($level, $line) if $lsyslogok;

	# print to screen if the loglevel is >= the level of the message
	return 1 unless maint_loglevel() >= $level;
	print _formatforscreen($level, $line);

	# If this is a fatal error, handle death gracefully.
	if( $level == LOG_ERR )
	{
		#sleep 10;	# DCW: let us see the error messages:-)
		maint_isexitforced(1);
		local $SIG{__DIE__}; # silence the die
		die();
	}
	return 1;
}	


=head2 B<maint_debug( $message )>

Generate a log entry to STDERR and syslog at DEBUG level.

=cut

sub maint_debug ($)
{
	my( $line) = @_;
	maint_log( LOG_DEBUG, $line );
}


=head2 B<maint_info( $message )>

Generate a log entry to STDERR and syslog at INFO level.

=cut

sub maint_info ($)
{
	my( $line) = @_;
	maint_log( LOG_INFO, $line );
}


=head2 B<maint_warning( $message )>

Generate a log entry to STDERR and syslog at WARNING level.

=cut

sub maint_warning ($)
{
	my( $line) = @_;
	maint_log( LOG_WARNING, $line );
}


=head2 B<maint_fatalerror( $message )>

Generate a log entry to STDERR and syslog at LOG_ERR level,
killing the program.

=cut

sub maint_fatalerror ($)
{
	my( $line) = @_;
	maint_log( LOG_ERR, $line );
}


# Internal to add error level prefix
sub _formatforscreen
{
	my ($level, $msg) = @_;
	return $msg unless exists $logstr{$level} && exists $logstr{$level};
	my $result      = '';
	my $prefix      = '';
	my $suffix      = '';
	my $colour      = '';
	my $resetcolour = '';
	if( maint_parsablelog() || !maint_colouriselog() )
	{
		$prefix = $logstr{$level} . ':' . $prefix;
	}
	else
	{
		$colour      = $logcolours{$level};
		$resetcolour = $colournormal;
	}
	unless( maint_parsablelog() )
	{
		$prefix = '[' . $prefix;
		$suffix = $suffix . ']';
	}
	if ($level == LOG_DEBUG || $level == LOG_INFO)
	{
		$result =
		  $colour . $prefix
		  . $resetcolour
		  . $msg
		  . $colour
		  . $suffix
		  . $resetcolour;
	}
	else
	{
		$result = $colour . $prefix . $msg . $suffix . $resetcolour;
	}
	if( maint_logperline() || maint_parsablelog() )
	{
		$result .= "\r\n";
	}
	else
	{
		$result .= ' ';
	}
	return $result;
}


=head2 B<maint_lognewline()>

Emits a newline unless logperline or machineread are set

=cut

sub maint_lognewline
{
	unless( maint_logperline() ||
		maint_parsablelog() ||
		maint_loglevel() < LOG_INFO )
	{
		print "\r\n";
	}
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

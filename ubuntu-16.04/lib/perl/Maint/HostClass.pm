package Maint::HostClass;

use strict;
use warnings;

require Exporter;
our @ISA         = qw(Exporter);
our %EXPORT_TAGS = (
    'all' => [
        qw(
            maint_reloadclasses
            maint_listclasses
            maint_listclasshosts
            maint_isinclass
          )
    ]
);
our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );
our @EXPORT    = qw(
);
our $VERSION = '0.02';

use Maint::Log qw(:all);
#use Maint::DB qw(:all);
use Maint::SafeFile qw(:all);
use Maint::Util qw(:all);
use Maint::ConfigInfo qw(:all);

our $hostclassfile = undef;
our $hostclasssource = undef;

our $class_forcereload = 0; # Do we invalidate the cache file if we have one?
our $class_cache = undef;

sub _class_linearise ($$);

=head1 NAME

Maint::HostClass - Hostclass system interface for Maint-based scripts

=head1 SYNOPSIS

    use Maint::HostClass qw(:all);
    
    maint_reloadclasses
    maint_listclasses
    maint_listclasshosts
    maint_isinclass

=head1 EXPORT

None by default, :all will export all symbols listed above.

=head1 DESCRIPTION

This module deals with handling host classes. Host classes describe a
standard hierarachical similarity structure using 3-tuples of
<child>, <parent>, <priority>

The source of hostclass info may be configured via the config/info file,
and is here accessed via the ConfigInfo module.

Say you had the following hostclass info:

  ALLHOST
  SERVER is a child of ALLHOST
  WEBSERVER is a child of SERVER
  web1 is a child of WEBSERVER
  CLIENT is a child of ALLHOST
  client1 is a child of CLIENT

that would look like:

  ''    	ALLHOST		50
  ALLHOST	SERVER		50
  SERVER	WEBSERVER	50
  WEBSERVER	web1		50
  ALLHOST	CLIENT		50
  CLIENT	client1		50

Most of the time you don't care about the order that a class inherits from its
parents so you can set the priority to be 50. The only time you DO care is
when a single child has more than one parent (multiple-inheritance) and
you want parent1 to be before parent2 in that child's list of hostclasses.
A greater numeric priority means "put first in the list".

Given this information, _class_linearise will work out the linear sequence of
most-general -> most-specific hostclasses that the given host is in.  The last
element of this list is always the hostname itself.

For "web1", the linearised host class list is:
ALLHOST, SERVER, WEBSERVER, web1. This reflects the fact that "web1"
is most specifically a WEBSERVER, then a SERVER, then an ALLHOST (which
every single host being managed might be in).

The linearisation is written out to the hostclass file (obtained from the
ConfigInfo module, the "hostclass:file" key)

There are some graphs which cannot be linearised - but you shouldn't ever
hit one. If you do, you really should take your structure out to be shot.

_classlist_sanity will check your hostclass data for cycles and duplicates.

=head1 FUNCTIONS

=cut

=head2 B<my $reload = maint_reloadclasses()>
=head2 B<maint_reloadclasses( $forcereload )>

Returns the current reload flag, or sets the flag.
Setting the flag will cause the cache to be invalidated and reloaded
from the database the next time any hostclass-related questions are asked.

=cut

sub maint_reloadclasses
{
    my $p = shift;
    $class_forcereload = $p if defined $p;
    return $class_forcereload;
}


#
# _init_config():
#	Read the hostclass:file and hostclass:source information from
#	the ConfigInfo module.  Store them in the module global variables
#	$hostclassfile and $hostclasssource.
#
sub _init_config ()
{
	unless( defined $hostclassfile )
	{
		$hostclassfile   = maint_getconfig( "hostclass:file" );
		$hostclasssource = maint_getconfig( "hostclass:source" );
	}
}


# my $listofhashes = _class_getall( $source );
#	Returns an array ref (a list of hashes) of ALL the hostclass data in
#	the $source.  $source may be "file:filename_in_configdir" or
#	"db:...." [to be decided later].  On error dies with log_error().
#
#	The returned data looks something like:
#
# (
#    {
#        'priority' => '50',
#        'parent' => undef,
#        'child' => 'ALLHOST'
#    },
#    {
#        'priority' => '50',
#        'parent' => 'ALLHOST',
#        'child' => 'CLIENT'
#    },
#    {
#        'priority' => '50',
#        'parent' => 'ALLHOST',
#        'child' => 'SERVER'
#    },
# No explicit error checking as DB errors will call log_error

sub _class_getall ($)
{
    my( $source ) = @_;

    unless( $source =~ s/^file:// )
    {
        maint_log(LOG_ERR,
		"Only 'file:' hostclass sources supported at this time ".
		"(not $source)");
    }

    my $confdir = maint_getconfigdir();
    my $conffile = "$confdir/$source";
    my $infh;

    unless( open( $infh, '<', $conffile ) )
    {
        maint_log(LOG_ERR,
		"Can't open hostclass source $conffile");
    }

    my $r = [];

    my $dontcare = <$infh>;	# first line is titles..  assume order is
    				# always parent,child,priority

    while( <$infh> )
    {
    	chomp;
	my @r = split( /\s*,\s*/, $_ );
	my $row = { parent => $r[0], child => $r[1], priority => $r[2] };
	push @$r, $row;
    }

    return $r; 
}


# internal function
sub _class_warndups_sort
{
	return ( ($a->{child} cmp $b->{child}) or ($a->{parent} cmp $b->{parent}) );
}

# internal function
sub _class_warndups ($)
{
	my $classtable = shift;
	my $r = [];

	$r = [sort _class_warndups_sort @$classtable];
	my $last = {child=>'', parent=>''};

	# It's sorted, so any duplicate entries are next to each other
	foreach my $ent (@$r) 
    {
		if ($ent->{child} eq $last->{child} and $ent->{parent} eq $last->{parent}) 
        {
			maint_log(LOG_WARNING, "Duplicate classtable entry: $ent->{child}, $ent->{parent}");
			return 0;
		}
		$last = $ent;
	}
	return 1;
}

# internal function
sub _class_sanity_r ($$@);
sub _class_sanity_r ($$@)
{
	my ($classtable, $class, @list) = @_;

	push @list, $class;
	my $parents = _class_parents ($class, $classtable);
	foreach my $parent (@$parents) {
		if (scalar (grep ($parent eq $_, @list)) != 0) {
			maint_log(LOG_WARNING, "Parent $parent of $class already in list [" . join ' ',@list . "]");
			return 0;
		}
		_class_sanity_r ($classtable, $parent, @list) or return 0;
	}

	return 1;
}

# check for loops. returns 1 if everything looks good
sub _class_sanity ($)
{
	my $classtable = shift;
	my $r;
	
	foreach my $class (@$classtable) {
		_class_sanity_r ($classtable, $class->{child}, ()) or return 0;
	}

	# mwj 2008-07-15
	# No longer required. Duplicates are not possible due to table constraints in the database, a far better way of
	# doing things.
	#
	# _class_warndups ($classtable) or return 0;

	return 1;
}

# internal function
sub _class_pri_sort
{
	return $b->{priority} <=> $a->{priority};
}

# internal function
sub _class_parents ($$)
{
	my ($class, $classtable) = @_;
	my $r = [];

	foreach my $ent (@$classtable) 
        {
		push (@$r, $ent) if ($ent->{child} eq $class);
	}

	$r = [sort _class_pri_sort @$r];

	my $result = [];
	foreach my $ent (@$r) 
        {
		push @$result, $ent->{parent};
	}

	return $result;
}

# internal function
# mergelist is a [[...], [...], ...]
# it stomps them all
# read the URL in the intro about this function
sub _class_merge ($) {
	my ($mergelist) = @_;
	my $linear = [];

	restart:
	
	$mergelist = [grep (scalar (@$_) > 0, @$mergelist)];
	return $linear if (scalar (@$mergelist) == 0);
	A: foreach my $ent (@$mergelist)
	{
		my $l = $ent;
		next if $#$l == -1;	# empty list, why not "unless @$l"
		my $head = $l->[0]; 

		# good head?
		foreach my $ent2 (@$mergelist)
		{
			next if $ent2 == $l;
			my $tail = [@$ent2];
			shift @$tail;
			if (scalar (grep ($_ eq $head, @$tail)) != 0) {
				next A;
			}
		}

		# the head isn't a member of any of the other tails
		# add the head is the linearisation and remove it from all lists
		push @$linear, $head;
		foreach (@$mergelist)
		{
			$_ = [grep ($_ ne $head, @$_)];
		}
		$mergelist = [grep (scalar (@$_) > 0, @$mergelist)];

		goto restart;
	}

	maint_log(LOG_WARNING, "Cannot reduce graph");
	return undef;
}

# linearise the class structure for a given class (first arg) in a given
# classtable
    
sub _class_linearise ($$)
{
	my( $class, $classtable ) = @_;
	my @classes;
	my $mergelist = [];
	my $linear;
	my $parents = _class_parents ($class, $classtable);

	foreach (@$parents)
	{
		push @$mergelist, _class_linearise($_, $classtable);
	}
	push @$mergelist, $parents;

	$linear = _class_merge ($mergelist);
	return undef unless defined $linear;
	unshift @$linear, $class;

	return $linear;
}


# setup all the classes information. Called automatically on demand
# Returns ref to the list of classes or undef on error
sub _class_setup ($)
{
	my( $hostname ) = @_;

	#maint_log(LOG_ERR, 'Hostname not passed to _class_setup') unless
	#	defined $hostname;

	maint_log(LOG_DEBUG, "Getting class info for '$hostname' and writing to $hostclassfile");

	my $classtable;
        return undef unless $classtable = _class_getall( $hostclasssource );

        # mwj 2008-7-15 -- this is bloody slow. commenting out for now
#	unless (_class_sanity($classtable))
#       {
#           maint_log(LOG_ERR, "Insane class table");
#           return undef;
#       }
	my $linear = _class_linearise($hostname, $classtable);
	unless( @$linear > 1 )
        {
            maint_log(LOG_WARNING, "No class data for host $hostname");
            return undef;
        }

	my( $fd, $handle ) = maint_safeopen($hostclassfile, 0644);
	unless( defined $fd )
        {
            maint_log( LOG_ERR, "Cannot safe_open $hostclassfile");
            return undef;
        }
	foreach (@$linear) 
        { 
            print $fd "$_\n"; 
        }
	unless( maint_safeclose($handle) )
        {
            maint_log(LOG_ERR, "Cannot safe_close $hostclassfile");
            return undef;
        }
        return $linear;
}

sub _classes_from_file
{
	my @classes = ();
	my $infh;
        unless( open( $infh, '<', $hostclassfile ) )
        {
            maint_log(LOG_DEBUG, "Cannot open class cache file: $hostclassfile" );
            return ();
        }
    
	while( <$infh> )
	{
		chomp;
		next if /^\s*$/;
		next if /^\#/;
		push @classes, $_;
	}
        close( $infh );
        return @classes;
}

sub _class_flatten ($$);
sub _class_flatten ($$)
{
	my ($class, $classmembers) = @_;
	my @flatten = ();

	if (exists($classmembers->{$class}))
	{
		foreach my $member (sort @{$classmembers->{$class}})
		{
			if ($member =~ /^[A-Z0-9]+$/)
			{
				# it's a class, recurse.
				push @flatten, _class_flatten($member, $classmembers);
			} else
			{
				push @flatten, $member;
			}
		}
		return @flatten;
	}
	return ();
}

=head2 B<maint_listclasses()>

Returns the class linearisation as an array of strings or undef on error

If maint_reloadclasses returns true, or the cache file is missing or empty,
this will force the list to be regenerated from the database and will refresh 
the contents of the local class cache file.

=cut

sub maint_listclasses () 
{
        return @$class_cache if
    	    defined $class_cache && !maint_reloadclasses();   # Save work...

	_init_config();

        my @classesfromfile;
        if( -f $hostclassfile )
	{
		@classesfromfile = _classes_from_file();
	}
        my $classes=[];
    
	if( maint_reloadclasses() || @classesfromfile == 0 )
        {
		maint_log(LOG_DEBUG, "Refreshing classes cache file");
		maint_reloadclasses(0); # Reset forcereload flag
		unless( $classes = _class_setup( maint_hostname() ) )
		{
		    maint_log(LOG_WARNING, "Cannot build class table from ".
				"source - using cache as fallback");
		}
	}
	else
	{
		@$classes = @classesfromfile;
	}
	unless( defined $classes && @$classes )
	{
		maint_log(LOG_ERR, "Cannot read any class data for this host - I have to die now");
	}
	maint_log(LOG_DEBUG, 'Read class data: [' . join (':', @$classes) . ']' );
	# Sanity check
	my $h = maint_hostname();
	unless( $h eq $$classes[0] )
	{
		maint_log(LOG_ERR, "Hostname in class list is not the same as our hostname, our=[$h], class is=[$$classes[0]]");
	}
	@$class_cache = @$classes;
	return @$classes;
}

=head2 B<maint_isinclass(string:classname)>

Returns a boolean reflecting whether the machine is a member of the
class specified.

=cut

sub maint_isinclass ($)
{
    my ($classname) = @_;
    return scalar grep {$_ eq $classname} maint_listclasses();
}

=head2 B<my @machines = maint_listclasshosts( $classname )>

Returns an array listing all the machines in a given class.

=cut

sub maint_listclasshosts ($)
{
    my( $classname) = @_;

    _init_config();

    maint_log(LOG_DEBUG, "Getting membership for class '$classname'");

    my $classtable;
    return () unless $classtable = _class_getall( $hostclasssource );
    
    unless( _class_sanity($classtable) )
    {
        maint_log(LOG_ERR, "Insane class table");
        return ();
    }

    # $classtable is an array ref (a list of hashes)

    my %classmembers;
    my %hosts;
    foreach my $classentry (@$classtable)
    {
	    $classmembers{$classentry->{parent}} //= [];
	    my $aref = $classmembers{$classentry->{parent}};
	    push @$aref, $classentry->{child};
	    if ($classentry->{child} !~ m/^[A-Z0-9]+$/)
	    {
		    $hosts{$classentry->{child}} = 1;
	    }
    }

    if( $classname !~ m/^[A-Z0-9]+$/ )
    {
	    return exists $hosts{$classname} ? ($classname) : ();
    }	    
	    
    # Ok, now %classmembers hashes class members correctly. Now find the
    # classname and recurse downwards
    my @flatmembers = _class_flatten($classname, \%classmembers);
    
    # Now uniqify the list.
    my %saw;
    return sort grep(!$saw{$_}++, @flatmembers);
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

package Maint::UserAccounts;

use strict;
use warnings;

require Exporter;
our @ISA         = qw(Exporter);
our %EXPORT_TAGS = (
    'all' => [
        qw(
            maint_validateusers
            maint_validategroups
            maint_getsiteusers
            maint_getsitegroups
            maint_getsanitygroups
            maint_getsanityusers
            maint_composepasswd
            maint_composegroup
            maint_composeamd
            maint_composeautofs
            maint_issystemuid
            maint_issystemgid
            maint_getusersfromfile
            maint_getgroupsfromfile
        )
    ]
);
our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );
our @EXPORT    = qw(
);
our $VERSION = '0.01';

#use List::Util 'first';
use Maint::Util qw(:all);
use Maint::Log qw(:all);
use Maint::ConfigInfo qw(:all);
#use Maint::HostClass qw(maint_listclasshosts);

our $configdir;
our $sysuidmax;
our $sysgidmax;
our $uidoffset;
our $gidoffset;
our $defaultdomain;
our $siteusersfilename;
our $sitegroupsfilename;
our $requiredrootusersfilename;
our $requiredgroupsfilename;

our $maxsuppgroups; # Max number of supplementary groups supported

our $usersbyid=undef;
our $groupsbyid=undef;
our $usersbyname=undef;
our $groupsbyname=undef;

=head1 NAME

Maint::UserAccounts - user account management as part of Maint

=head1 SYNOPSIS

    use Maint::UserAccounts qw(:all);
    maint_getsiteusers
    maint_getsitegroups
    maint_getsanitygroups
    maint_getsanityusers
    maint_composepasswd
    maint_composegroup
    maint_composeamd
    maint_composeautofs
    maint_issystemuid
    maint_issystemgid
    maint_getusersfromfile
    maint_getgroupsfromfile

=head1 EXPORT

None by default, :all will export:

maint_getsiteusers
maint_getsitegroups
maint_getsanitygroups
maint_getsanityusers
maint_composepasswd
maint_composegroup
maint_issystemuid
maint_issystemgid
maint_getusersfromfile
maint_getgroupsfromfile
maint_composeamd
maint_composeautofs

=cut

=head1 DATA STRUCTURES

=cut

=head2 B<USERSBYID>

This is keyed by UID, the values are hashes with the following keys:

    homedirremotepath   => Path on remote NFS server to home dir (may be undef)
    homedirremoteserver => NFS server host name (may be undef)
    pass                => Literal unix password for passwd file.
                           This should never be undef or blank!
    uid                 => Unix UID
    gecos               => Unix gecos any way you like it
    name                => Unix username
    shell               => Fully pathed shell.
    home                => Local home directory (ie where NFS is mounted to)
    gid                 => Primary GID


This data structure conforms to this example:


 {
    '59099' => {
         'homedirremotepath' => '/export1/users/c/unclelumpy',
         'homedirremoteserver' => 'nfsserver1',
         'pass' => '*',
         'uid' => 59099,
         'gecos' => 'Uncle Lumpy (Fish Doctor)',
         'name' => 'ulumpy',
         'shell' => '/bin/bash',
         'home' => '/homes/ulumpy',
         'gid' => '59098'
    },
    '59098' => {
          'homedirremotepath' => undef,
          'homedirremoteserver' => undef,
          'pass' => '*',
          'uid' => 59098,
          'gecos' => 'Suexec cgi account for someone',
          'name' => 'someone_webuser',
          'shell' => '/bin/true',
          'home' => '/',
          'gid' => '59097'
    },
    ...
 }


=cut

=head2 B<USERSBYNAME>

This is keyed by user name, the values are hashes as USERSBYID above.

=cut

=head2 B<GROUPSBYID>

This is keyed by GID, the values are hashes with the following keys:

    userlist        => Comma seperate list of unix usersnames who are
                       supplementary members of this group.
    pass            => Unix group file password, see man -S5 group, should be *
    name            => Unix group name
    gid             => Unix GID

This data structure conforms to this example:


 {
    '59098' => {
        'userlist' => 'wibble1,wibble2',
        'pass' => '*',
        'name' => 'group1',
        'gid' => 59098
    },
    '59099' => {
        'userlist' => '',
        'pass' => '*',
        'name' => 'wibble2',
        'gid' => 59099
    },
    ...
 }

=cut

=head2 B<GROUPSBYNAME>

This is keyed by group name, the values are hashes as GROUPSBYID above.

=cut

=head1 FUNCTIONS

=cut


#
# _init_config():
#	Read the configdir information from the ConfigInfo module.  Store
#	it in the module global variable $configdir.
#
sub _init_config ()
{
	unless( defined $configdir )
	{
		$configdir = maint_getconfigdir();
		$maxsuppgroups = maint_getconfig( "users:maxgroups" ) // 16;
		$sysuidmax = maint_getconfig( "users:sysuidmax" ) // 99;
		$sysgidmax = maint_getconfig( "users:sysgidmax" ) // 99;
		$uidoffset = maint_getconfig( "users:uidoffset" ) // 0;
		$gidoffset = maint_getconfig( "users:gidoffset" ) // 0;
	        $requiredrootusersfilename =
		    maint_getconfig( "users:requiredrootusers" ) //
		    "required-root-users.txt";
	        $requiredgroupsfilename =
		    maint_getconfig( "users:requiredgroups" ) //
		    "required-groups.txt";
	        $siteusersfilename = maint_getconfig( "users:users" ) //
		    "file:site-users.txt";
	        $sitegroupsfilename = maint_getconfig( "users:groups" ) //
		    "file:site-groups.txt";
		$defaultdomain = maint_getconfig( "domain" ) //
		    "no.domain.at.all";
	}
}


#
# my @result = _load_file_array( $filename );
#	Load the contents (one entry per line, blank lines and # lines
#	ignored) of $filename, return them as an array of chomped lines.
#
sub _load_file_array ($)
{
	my( $filename ) = @_;
	my @result;
	open( my $infh, '<', $filename ) ||
	maint_fatalerror( "Cannot read $filename" );
	while( <$infh> )
	{
		chomp;
		next if /^\s*$/ || /^#/;
		unless( $_ )
		{
		    maint_warning( "$filename has a blank entry - skipping" );
		    next;
		}
		push @result, $_;
	}
	close $infh;
	return @result;
}


=head2 B<maint_getsanityusers()>

Returns the list of must-have users (who would have accounts B<and>
root access everywhere to use as a sanity check.

=cut

sub maint_getsanityusers
{
    _init_config();
    my $sanity_users_file  = "$configdir/$requiredrootusersfilename";

    return _load_file_array( $sanity_users_file );
}


=head2 B<maint_getsanitygroups()>

Returns the list of must-have groups which must exist everywhere to use as a 
sanity check. This should contain the primary group of the 
sanity-check-required-users.

=cut

sub maint_getsanitygroups
{
    _init_config();
    my $sanity_groups_file  = "$configdir/$requiredgroupsfilename";
    return _load_file_array( $sanity_groups_file );
}


=head2 B<my $string = maint_composepasswd( $byidhashref )>

Takes a USERSBYID data structure and builds a passwd file formatted string.
Returns the string or undef on error.

=cut

sub maint_composepasswd
{
    my $users = shift;
    my $lines='';
    foreach my $uid (sort {$a <=> $b} keys %$users)
    {
	my $ur = $users->{$uid};
        my @a = (
            $ur->{name},
            $ur->{pass},
            $ur->{uid},
            $ur->{gid},
            $ur->{gecos},
            $ur->{home},
            $ur->{shell},
        );
        my $ent = join(':', map { $_ // '' } @a);
        $lines .= $ent . "\n";
    }
    return $lines;
}


=head2 B<my $string = maint_composegroup( $byidhashref )>

Takes a GROUPSBYID data structure and builds a group file formatted string.
Returns the string or undef on error.

=cut

sub maint_composegroup
{
    my $groups = shift;
    my $lines='';
    foreach my $gid (sort {$a <=> $b} keys %$groups)
    {
	my $gr = $groups->{$gid};
        my @a  = (
            $gr->{name},
            $gr->{pass},
            $gr->{gid},
            $gr->{userlist},
        );
        my $ent = join( ':', map { $_ // '' } @a );
        $lines .= $ent . "\n";
    }
    return $lines;
}


=head2 B<my $string = maint_composeamd( $byidhashref )>

Takes a USERSBYID data structure and builds an amd file formatted string.
Returns the string or undef on error.

=cut

sub maint_composeamd
{
    my $users = shift;
    my $lines='';
    foreach my $uid (sort {$a <=> $b} keys %$users)
    {
	my $ur    = $users->{$uid};
        my $name  = $ur->{name};
        my $rserv = $ur->{'homedirremoteserver'};
        my $rpath = $ur->{'homedirremotepath'};
        unless( defined $name && defined $rserv && defined $rpath )
        {
            maint_debug( "Ignoring user $name, no central home dir" );
            next;
        }
        my $ent = "$name\trhost:=$rserv;rfs:=$rpath\n";
        $lines .= $ent;
    }
    return $lines;
}


=head2 B<my $string = maint_composeautofs( $byidhashref );>

Takes a USERSBYID data structure and builds an autofs file formatted string.
Returns the string or undef on error.

=cut

sub maint_composeautofs
{
    my $users = shift;
    my $lines='';

    foreach my $uid (sort {$a <=> $b} keys %$users)
    {
	my $ur    = $users->{$uid};
        my $name  = $ur->{name};
        my $rserv = $ur->{'homedirremoteserver'};
        my $rpath = $ur->{'homedirremotepath'};
        unless( $name && $rserv && $rpath )
        {
            maint_debug( "Ignoring user $name, no central home dir" );
            next;
        }
        my $ent = "$name\t$rserv:$rpath\n";
        $lines .= $ent;
    }
    return $lines;
}


=head2 B<maint_issystemuid( $uid );>

Returns TRUE if uid is a system uid, that is between 0 and $sysuidmax inclusive.

=cut

sub maint_issystemuid
{
    my $id=shift;
    return $id <= $sysuidmax;
}


=head2 B<maint_issystemgid( $gid );>

Returns TRUE if gid is a system gid, that is between 0 and $sysgidmax inclusive.

=cut

sub maint_issystemgid
{
    my $id=shift;
    return $id <= $sysgidmax;
}

=head2 B<my( $byid, $byname ) = maint_getusersfromfile( $filename );>

Reads a unix passwd-format file ($filename) and returns
(USERSBYID, USERSBYNAME) containing all valid users. Warnings are given
and bad entries will be dropped.  Returns (undef,undef) if we can't
open $filename.

=cut

sub maint_getusersfromfile
{
    my $file = shift;
    my %byid;
    my %byname;
    unless( -f $file )
    {
        maint_warning( "$file doesn't seem to exist or be a file" );
        return ( undef, undef );
    }
    my $pfh;
    unless( open $pfh, '<', $file )
    {
        maint_warning( "Cannot read file $file" );
        return ( undef, undef );
    }

    while( <$pfh> )
    {
    	chomp;
        my( $uname, $pword, $uid, $gid, $gecos, $home, $shell, @junk ) =
		split /:/, $_;
        if( $byid{$uid} )
        {
            maint_warning( "Duplicate uid $uid in $file" );
            next;
        }
        if( $byname{$uname} )
        {
            maint_warning( "Duplicate user $uname in $file" );
            next;
        }

	my %record = (
		name  => $uname,
		pass  => $pword,
		uid   => $uid,
		gid   => $gid,
		gecos => $gecos,
		home  => $home,
		shell => $shell
	);
        $byid{$uid}     = \%record;
        $byname{$uname} = \%record;
    }
    close $pfh;
    return ( \%byid, \%byname );
}


=head2 B<my( $byid, $byname ) = maint_getgroupsfromfile( $filename );>

Reads a unix group-format file ($filename) and returns (GROUPSBYID,
GROUPSBYNAME) containing all valid groups. Warnings are given and
bad entries will be dropped.  Returns (undef,undef) if we can't
open $filename.

=cut

sub maint_getgroupsfromfile
{
    my $file = shift;
    my %byid;
    my %byname;
    unless( -f $file )
    {
        maint_warning( "$file doesn't seem to exist or be a file" );
        return ( undef, undef );
    }
    my $pfh;
    unless( open( $pfh, '<', $file ) )
    {
        maint_warning( "Cannot read file $file" );
        return ( undef, undef );
    }

    while( <$pfh> )
    {
        chomp;
        my( $gname, $pword, $gid, $userlist, @junk ) = split /:/, $_;
        if( $byid{$gid} )
        {
            maint_warning( "Duplicate gid $gid in $file" );
            next;
        }
        if( $byname{$gname} )
        {
            maint_warning( "Duplicate group $gname in $file" );
            next;
        }
	my %record = (
		name     => $gname,
		pass     => $pword,
		gid      => $gid,
		userlist => $userlist
	);
        $byid{$gid}     = \%record;
        $byname{$gname} = \%record;
    }
    close $pfh;
    return ( \%byid, \%byname );
}


=head2 B<my( $byid, $byname ) = maint_getsiteusers()>

Get all the defined and active user accounts for this site,
doing some basic checks for duplicates and invalid uids.

The source of site users is stored in $siteusersfilename,
and may be "file:filename_in_configdir" or (later) "db:....".
On error dies with maint_fatalerror().

Returns (USERSBYID, USERSBYNAME) which are described below or (undef,undef)
on error. Will maint_fatalerror() die on extreme errors.

Each source filename line has the following fields:

	username,uid,gid,gecos,home,shell,rhomedirserver,rhomepath,disabled

Caches the results in memory from the first call, only consults the
$source once.

=cut

sub maint_getsiteusers
{
    _init_config();

    return ( $usersbyid, $usersbyname ) if
    	defined $usersbyid && defined $usersbyname;

    unless( $siteusersfilename =~ s/^file:// )
    {
        maint_fatalerror(
		"Only 'file:' site user sources supported at this time ".
		"(not $siteusersfilename)" );
    }

    my $conffile = "$configdir/$siteusersfilename";
    open( my $infh, '<', $conffile )
    	|| maint_fatalerror( "Can't open site user source $conffile" );
    $_ = <$infh>;	# discard first line, headers

    my %byname;
    my %byid;
    while( <$infh> )
    {
    	chomp;
        my( $uname, $uid, $gid, $gecos, $home, $shell,
	    $rhomedirserver, $rhomepath, $disabled ) = split(/:/, $_ );
        if( maint_issystemuid($uid) )
        {
            maint_warning( "Skipping system user name=$uname, uid $uid <= ".
	    		   "$sysuidmax" );
            next;
        }
        maint_fatalerror( "Impossible! duplicate site uid $uid" )
		if exists $byid{$uid};
        maint_fatalerror( "Impossible! duplicate site username $uname" )
		if exists $byname{$uname};

        $gecos = $uname unless $gecos;
        $shell = '/bin/true' if $disabled;
	#print "debug: $uname, disabled=$disabled, shell=$shell\n";
        $rhomedirserver .= ".$defaultdomain." if
		defined $rhomedirserver && length($rhomedirserver) &&
                $rhomedirserver !~ m/\./ && $defaultdomain =~ /\./;
	my %record = (
	    name                => $uname,
	    pass                => '*',
	    uid                 => $uid,
	    gid                 => $gid, 
            gecos               => $gecos,
	    home                => $home,
	    shell               => $shell, 
            homedirremoteserver => $rhomedirserver, 
            homedirremotepath   => $rhomepath
	);
        $byid{$uid}     = \%record;
        $byname{$uname} = \%record;
    }
    close( $infh );

    my $nusers = keys %byid;
    maint_info( "Found $nusers site users" );

    $usersbyid = \%byid;
    $usersbyname = \%byname;
    return ( $usersbyid, $usersbyname );
}


=head2 B<my( $byid, $byname ) = maint_getsitegroups()>

Get all the defined and active group accounts from $sitegroupsfilename, doing
some basic checks for duplicity and invalid gids, caching the results in
memory from the first call, will only consult the $sitegroupsfilename once.
On serious error dies with maint_fatalerror().
Returns (groupsbyid, groupsbyname) which are described below or (undef, undef)

$sitegroupsfilename may be "file:filename_in_configdir" or (later) "db:....".


=cut

sub maint_getsitegroups
{
    _init_config();

    return ( $groupsbyid, $groupsbyname )
    	if defined $groupsbyid && defined $groupsbyname;

    unless( $sitegroupsfilename =~ s/^file:// )
    {
        maint_fatalerror(
		"Only 'file:' site group sources supported at this time ".
		"(not $sitegroupsfilename)" );
    }

    my $conffile = "$configdir/$sitegroupsfilename";
    open( my $infh, '<', $conffile ) ||
	maint_fatalerror( "Can't read site groups file $conffile" );
    $_ = <$infh>;	# discard first line, headers

    my %byname;
    my %byid;

    while( <$infh> )
    {
	chomp;
	my( $gname, $gid, $members ) = split( /,/, $_, 3 );
        if( maint_issystemgid($gid) )
        {
            maint_warning( "Skipping system group name=$gname, gid $gid <=".
	    		   " $sysgidmax" );
            next;
        }
        maint_fatalerror( "Impossible! duplicate site gid $gid")
		if exists $byid{$gid};
        maint_fatalerror( "Impossible! Duplicate site group name $gname")
		if exists $byname{$gname};
	my %record = (
		name    => $gname,
		pass    => '*',
		gid     => $gid,
		userlist=> $members
	);
        $byid{$gid}     = \%record;
        $byname{$gname} = \%record;
    }
    close( $infh );

    my $ngroups = keys %byid;
    if( $ngroups == 0 )
    {
        maint_warning( "Cannot get any site groups" );
        return( undef, undef );
    }
    maint_info( "Found $ngroups site groups" );

    $groupsbyid   = \%byid;
    $groupsbyname = \%byname;
    return ( $groupsbyid, $groupsbyname );
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

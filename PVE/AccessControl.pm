package PVE::AccessControl;

use strict;
use warnings;
use Encode;
use Crypt::OpenSSL::Random;
use Crypt::OpenSSL::RSA;
use Net::SSLeay;
use MIME::Base64;
use Digest::SHA;
use Digest::HMAC_SHA1;
use URI::Escape;
use LWP::UserAgent;
use PVE::Tools qw(run_command lock_file file_get_contents split_list safe_print);
use PVE::Cluster qw(cfs_register_file cfs_read_file cfs_write_file cfs_lock_file);
use PVE::JSONSchema;

use PVE::Auth::Plugin;
use PVE::Auth::AD;
use PVE::Auth::LDAP;
use PVE::Auth::PVE;
use PVE::Auth::PAM;

use Data::Dumper; # fixme: remove

# load and initialize all plugins

PVE::Auth::AD->register();
PVE::Auth::LDAP->register();
PVE::Auth::PVE->register();
PVE::Auth::PAM->register();
PVE::Auth::Plugin->init();

# $authdir must be writable by root only!
my $confdir = "/etc/pve";
my $authdir = "$confdir/priv";
my $authprivkeyfn = "$authdir/authkey.key";
my $authpubkeyfn = "$confdir/authkey.pub";
my $pve_www_key_fn = "$confdir/pve-www.key";

my $ticket_lifetime = 3600*2; # 2 hours

Crypt::OpenSSL::RSA->import_random_seed();

cfs_register_file('user.cfg', 
		  \&parse_user_config,  
		  \&write_user_config);


sub verify_username {
    PVE::Auth::Plugin::verify_username(@_);
}

sub pve_verify_realm {
    PVE::Auth::Plugin::pve_verify_realm(@_);
}

sub lock_user_config {
    my ($code, $errmsg) = @_;

    cfs_lock_file("user.cfg", undef, $code);
    if (my $err = $@) {
	$errmsg ? die "$errmsg: $err" : die $err;
    }
}

my $pve_auth_pub_key;
sub get_pubkey {    

    return $pve_auth_pub_key if $pve_auth_pub_key;

    my $input = PVE::Tools::file_get_contents($authpubkeyfn); 

    $pve_auth_pub_key = Crypt::OpenSSL::RSA->new_public_key($input);

    return $pve_auth_pub_key;
}

my $csrf_prevention_secret;
my $get_csrfr_secret = sub {
    if (!$csrf_prevention_secret) {
	my $input = PVE::Tools::file_get_contents($pve_www_key_fn); 
	$csrf_prevention_secret = Digest::SHA::sha1_base64($input);
    }
    return $csrf_prevention_secret;
};

sub assemble_csrf_prevention_token {
    my ($username) = @_;

    my $timestamp = sprintf("%08X", time());

    my $digest = Digest::SHA::sha1_base64("$timestamp:$username", &$get_csrfr_secret());

    return "$timestamp:$digest"; 
}

sub verify_csrf_prevention_token {
    my ($username, $token, $noerr) = @_;

    if ($token =~ m/^([A-Z0-9]{8}):(\S+)$/) {
	my $sig = $2;
	my $timestamp = $1;
	my $ttime = hex($timestamp);

	my $digest = Digest::SHA::sha1_base64("$timestamp:$username", &$get_csrfr_secret());

	my $age = time() - $ttime;
	return if ($digest eq $sig) && ($age > -300) && ($age < $ticket_lifetime);
    }

    die "Permission denied - invalid csrf token\n" if !$noerr;

    return undef;
}

my $pve_auth_priv_key;
sub get_privkey {

    return $pve_auth_priv_key if $pve_auth_priv_key;

    my $input = PVE::Tools::file_get_contents($authprivkeyfn); 

    $pve_auth_priv_key = Crypt::OpenSSL::RSA->new_private_key($input);

    return $pve_auth_priv_key;
}

sub assemble_ticket {
    my ($username) = @_;

    my $rsa_priv = get_privkey();

    my $timestamp = sprintf("%08X", time());

    my $plain = "PVE:$username:$timestamp";

    my $ticket = $plain . "::" . encode_base64($rsa_priv->sign($plain), '');

    return $ticket;
}

sub verify_ticket {
    my ($ticket, $noerr) = @_;

    if ($ticket && $ticket =~ m/^(PVE:\S+)::([^:\s]+)$/) {
	my $plain = $1;
	my $sig = $2;

	my $rsa_pub = get_pubkey();
	if ($rsa_pub->verify($plain, decode_base64($sig))) {
	    if ($plain =~ m/^PVE:(\S+):([A-Z0-9]{8})$/) {
		my $username = $1;
		my $timestamp = $2;
		my $ttime = hex($timestamp);

		my $age = time() - $ttime;

		if (PVE::Auth::Plugin::verify_username($username, 1) &&
		    ($age > -300) && ($age < $ticket_lifetime)) {
		    return wantarray ? ($username, $age) : $username;
		}
	    }
	}
    }

    die "permission denied - invalid ticket\n" if !$noerr;

    return undef;
}

# VNC tickets
# - they do not contain the username in plain text
# - they are restricted to a specific resource path (example: '/vms/100')
sub assemble_vnc_ticket {
    my ($username, $path) = @_;

    my $rsa_priv = get_privkey();

    my $timestamp = sprintf("%08X", time());

    my $plain = "PVEVNC:$timestamp";

    $path = normalize_path($path);

    my $full = "$plain:$username:$path";

    my $ticket = $plain . "::" . encode_base64($rsa_priv->sign($full), '');

    return $ticket;
}

sub verify_vnc_ticket {
    my ($ticket, $username, $path, $noerr) = @_;

    if ($ticket && $ticket =~ m/^(PVEVNC:\S+)::([^:\s]+)$/) {
	my $plain = $1;
	my $sig = $2;
	my $full = "$plain:$username:$path";

	my $rsa_pub = get_pubkey();
	# Note: sign only match if $username and  $path is correct
	if ($rsa_pub->verify($full, decode_base64($sig))) {
	    if ($plain =~ m/^PVEVNC:([A-Z0-9]{8})$/) {
		my $ttime = hex($1);

		my $age = time() - $ttime;

		if (($age > -20) && ($age < 40)) {
		    return 1;
		}
	    }
	}
    }

    die "permission denied - invalid vnc ticket\n" if !$noerr;

    return undef;
}

sub assemble_spice_ticket {
    my ($username, $vmid, $node) = @_;

    my $rsa_priv = get_privkey();

    my $timestamp = sprintf("%08x", time());

    my $randomstr = "PVESPICE:$timestamp:$vmid:$node:" . rand(10);

    # this should be uses as one-time password
    # max length is 60 chars (spice limit)
    # we pass this to qemu set_pasword and limit lifetime there
    # keep this secret
    my $ticket = Digest::SHA::sha1_hex($rsa_priv->sign($randomstr));

    # Note: spice proxy connects with HTTP, so $proxyticket is exposed to public
    # we use a signature/timestamp to make sure nobody can fake such ticket
    # an attacker can use this $proxyticket, but he will fail because $ticket is
    # private.
    # The proxy need to be able to extract/verify the ticket
    # Note: data needs to be lower case only, because virt-viewer needs that
    # Note: RSA signature are too long (>=256 charaters) and makes problems with remote-viewer

    my $secret = &$get_csrfr_secret();
    my $plain = "pvespiceproxy:$timestamp:$vmid:" . lc($node);

    # produces 40 characters
    my $sig = unpack("H*", Digest::SHA::sha1($plain, &$get_csrfr_secret()));

    #my $sig =  unpack("H*", $rsa_priv->sign($plain)); # this produce too long strings (512)

    my $proxyticket = $plain . "::" . $sig;

    return ($ticket, $proxyticket);
}

sub verify_spice_connect_url {
    my ($connect_str) = @_;

    # Note: we pass the spice ticket as 'host', so the
    # spice viewer connects with "$ticket:$port"

    return undef if !$connect_str;

    if ($connect_str =~m/^pvespiceproxy:([a-z0-9]{8}):(\d+):(\S+)::([a-z0-9]{40}):(\d+)$/) {
	my ($timestamp, $vmid, $node, $hexsig, $port) = ($1, $2, $3, $4, $5, $6);
	my $ttime = hex($timestamp);
	my $age = time() - $ttime;

	# use very limited lifetime - is this enough?
	return undef if !(($age > -20) && ($age < 40));

	my $plain = "pvespiceproxy:$timestamp:$vmid:$node";
	my $sig = unpack("H*", Digest::SHA::sha1($plain, &$get_csrfr_secret()));

	if ($sig eq $hexsig) {
	    return ($vmid, $node, $port);
	} 
    }

    return undef;
}

sub read_x509_subject_spice {
    my ($filename) = @_;

    # read x509 subject
    my $bio = Net::SSLeay::BIO_new_file($filename, 'r');
    my $x509 = Net::SSLeay::PEM_read_bio_X509($bio);
    Net::SSLeay::BIO_free($bio);
    my $nameobj = Net::SSLeay::X509_get_subject_name($x509);
    my $subject = Net::SSLeay::X509_NAME_oneline($nameobj);
    Net::SSLeay::X509_free($x509);
  
    # remote-viewer wants comma as seperator (not '/')
    $subject =~ s!^/!!;
    $subject =~ s!/(\w+=)!,$1!g;

    return $subject;
}

# helper to generate SPICE remote-viewer configuration
sub remote_viewer_config {
    my ($authuser, $vmid, $node, $proxy, $title, $port) = @_;

    if (!$proxy) {
	my $host = `hostname -f` || PVE::INotify::nodename();
	chomp $host;
	$proxy = $host;
    }

    my ($ticket, $proxyticket) = assemble_spice_ticket($authuser, $vmid, $node);

    my $filename = "/etc/pve/local/pve-ssl.pem";
    my $subject = read_x509_subject_spice($filename);

    my $cacert = PVE::Tools::file_get_contents("/etc/pve/pve-root-ca.pem", 8192);
    $cacert =~ s/\n/\\n/g;

    my $config = {
	'secure-attention' => "Ctrl+Alt+Ins",
	'toggle-fullscreen' => "Shift+F11",
	'release-cursor' => "Ctrl+Alt+R",
	type => 'spice',
	title => $title,
	host => $proxyticket, # this break tls hostname verification, so we need to use 'host-subject'
	proxy => "http://$proxy:3128",
	'tls-port' => $port,
	'host-subject' => $subject,
	ca => $cacert,
	password => $ticket,
	'delete-this-file' => 1,
    };

    return ($ticket, $proxyticket, $config);
}

sub check_user_exist {
    my ($usercfg, $username, $noerr) = @_;

    $username = PVE::Auth::Plugin::verify_username($username, $noerr);
    return undef if !$username;
 
    return $usercfg->{users}->{$username} if $usercfg && $usercfg->{users}->{$username};

    die "no such user ('$username')\n" if !$noerr;
 
    return undef;
}

sub check_user_enabled {
    my ($usercfg, $username, $noerr) = @_;

    my $data = check_user_exist($usercfg, $username, $noerr);
    return undef if !$data;

    return 1 if $data->{enable};

    #return 1 if $username eq 'root@pam'; # root is always enabled

    die "user '$username' is disabled\n" if !$noerr;
 
    return undef;
}

sub verify_one_time_pw {
    my ($usercfg, $username, $tfa_cfg, $otp) = @_;

    my $type = $tfa_cfg->{type};

    die "missing one time password for Factor-two authentication '$type'\n" if !$otp;

    # fixme: proxy support?
    my $proxy;

    if ($type eq 'yubico') {
	my $keys = $usercfg->{users}->{$username}->{keys};
	yubico_verify_otp($otp, $keys, $tfa_cfg->{url}, $tfa_cfg->{id}, $tfa_cfg->{key}, $proxy);
    } elsif ($type eq 'oath') {
	my $keys = $usercfg->{users}->{$username}->{keys};
	oath_verify_otp($otp, $keys, $tfa_cfg->{step}, $tfa_cfg->{digits});
    } else {
	die "unknown tfa type '$type'\n";
    }
}

# password should be utf8 encoded
# Note: some pluging delay/sleep if auth fails
sub authenticate_user {
    my ($username, $password, $otp) = @_;

    die "no username specified\n" if !$username;
 
    my ($ruid, $realm);

    ($username, $ruid, $realm) = PVE::Auth::Plugin::verify_username($username);

    my $usercfg = cfs_read_file('user.cfg');

    check_user_enabled($usercfg, $username);

    my $ctime = time();
    my $expire = $usercfg->{users}->{$username}->{expire};

    die "account expired\n" if $expire && ($expire < $ctime);

    my $domain_cfg = cfs_read_file('domains.cfg');

    my $cfg = $domain_cfg->{ids}->{$realm};
    die "auth domain '$realm' does not exists\n" if !$cfg;
    my $plugin = PVE::Auth::Plugin->lookup($cfg->{type});
    $plugin->authenticate_user($cfg, $realm, $ruid, $password);

    if ($cfg->{tfa}) {
	my $tfa_cfg = PVE::Auth::Plugin::parse_tfa_config($cfg->{tfa});
	verify_one_time_pw($usercfg, $username, $tfa_cfg, $otp);
    }

    return $username;
}

sub domain_set_password {
    my ($realm, $username, $password) = @_;

    die "no auth domain specified" if !$realm;

    my $domain_cfg = cfs_read_file('domains.cfg');

    my $cfg = $domain_cfg->{ids}->{$realm};
    die "auth domain '$realm' does not exists\n" if !$cfg;
    my $plugin = PVE::Auth::Plugin->lookup($cfg->{type});
    $plugin->store_password($cfg, $realm, $username, $password);
}

sub add_user_group {

    my ($username, $usercfg, $group) = @_;
    $usercfg->{users}->{$username}->{groups}->{$group} = 1;
    $usercfg->{groups}->{$group}->{users}->{$username} = 1;
}

sub delete_user_group {

    my ($username, $usercfg) = @_;
    
    foreach my $group (keys %{$usercfg->{groups}}) {

	delete ($usercfg->{groups}->{$group}->{users}->{$username}) 
	    if $usercfg->{groups}->{$group}->{users}->{$username};
    }
}

sub delete_user_acl {

    my ($username, $usercfg) = @_;

    foreach my $acl (keys %{$usercfg->{acl}}) {

	delete ($usercfg->{acl}->{$acl}->{users}->{$username}) 
	    if $usercfg->{acl}->{$acl}->{users}->{$username};
    }
}

sub delete_group_acl {

    my ($group, $usercfg) = @_;

    foreach my $acl (keys %{$usercfg->{acl}}) {

	delete ($usercfg->{acl}->{$acl}->{groups}->{$group}) 
	    if $usercfg->{acl}->{$acl}->{groups}->{$group};
    }
}

sub delete_pool_acl {

    my ($pool, $usercfg) = @_;

    my $path = "/pool/$pool";

    foreach my $aclpath (keys %{$usercfg->{acl}}) {
	delete ($usercfg->{acl}->{$aclpath})
	    if $usercfg->{acl}->{$aclpath} eq 'path';
    }
}

# we automatically create some predefined roles by splitting privs
# into 3 groups (per category)
# root: only root is allowed to do that
# admin: an administrator can to that
# user: a normak user/customer can to that
my $privgroups = {
    VM => {
	root => [],
	admin => [	     
	    'VM.Config.Disk', 
	    'VM.Config.CPU', 
	    'VM.Config.Memory', 
	    'VM.Config.Network', 
	    'VM.Config.HWType',
	    'VM.Config.Options', # covers all other things 
	    'VM.Allocate', 
	    'VM.Clone', 
	    'VM.Migrate',
	    'VM.Monitor', 
	    'VM.Snapshot', 
	],
	user => [
	    'VM.Config.CDROM', # change CDROM media
		'VM.Config.UploadISO', # upload own ISOs
	    'VM.Console', 
	    'VM.Backup',
	    'VM.PowerMgmt',
	],
	audit => [ 
	    'VM.Audit',
	],
    },
    Sys => {
	root => [
	    'Sys.PowerMgmt',	 
	    'Sys.Modify', # edit/change node settings
	],
	admin => [
	    'Permissions.Modify',
	    'Sys.Console',    
	    'Sys.Syslog',
	],
	user => [],
	audit => [
	    'Sys.Audit',
	],
    },
    Datastore => {
	root => [],
	admin => [
	    'Datastore.Allocate',
	    'Datastore.AllocateTemplate',
	],
	user => [
	    'Datastore.AllocateSpace',
	],
	audit => [
	    'Datastore.Audit',
	],
    },
    User => {
	root => [
	    'Realm.Allocate',
	],
	admin => [
	    'User.Modify',
	    'Group.Allocate', # edit/change group settings
	    'Realm.AllocateUser', 
	],
	user => [],
	audit => [],
    },
    Pool => {
	root => [],
	admin => [
	    'Pool.Allocate', # create/delete pools
	],
	user => [],
	audit => [],
    },
};

my $valid_privs = {};

my $special_roles = {
    'NoAccess' => {}, # no priviledges
    'Administrator' => $valid_privs, # all priviledges
};

sub create_roles {

    foreach my $cat (keys %$privgroups) {
	my $cd = $privgroups->{$cat};
	foreach my $p (@{$cd->{root}}, @{$cd->{admin}}, 
		       @{$cd->{user}}, @{$cd->{audit}}) {
	    $valid_privs->{$p} = 1;
	}
	foreach my $p (@{$cd->{admin}}, @{$cd->{user}}, @{$cd->{audit}}) {

	    $special_roles->{"PVE${cat}Admin"}->{$p} = 1;
	    $special_roles->{"PVEAdmin"}->{$p} = 1;
	}
	if (scalar(@{$cd->{user}})) {
	    foreach my $p (@{$cd->{user}}, @{$cd->{audit}}) {
		$special_roles->{"PVE${cat}User"}->{$p} = 1;
	    }
	}
	foreach my $p (@{$cd->{audit}}) {
	    $special_roles->{"PVEAuditor"}->{$p} = 1;
	}
    }

    $special_roles->{"PVETemplateUser"} = { 'VM.Clone' => 1, 'VM.Audit' => 1 };
};

create_roles();

sub add_role_privs {
    my ($role, $usercfg, $privs) = @_;

    return if !$privs;

    die "role '$role' does not exist\n" if !$usercfg->{roles}->{$role};

    foreach my $priv (split_list($privs)) {
	if (defined ($valid_privs->{$priv})) {
	    $usercfg->{roles}->{$role}->{$priv} = 1;
	} else {
	    die "invalid priviledge '$priv'\n";
	} 
    }	
}

sub normalize_path {
    my $path = shift;

    $path =~ s|/+|/|g;

    $path =~ s|/$||;

    $path = '/' if !$path;

    $path = "/$path" if $path !~ m|^/|;

    return undef if $path !~ m|^[[:alnum:]\.\-\_\/]+$|;

    return $path;
} 


PVE::JSONSchema::register_format('pve-groupid', \&verify_groupname);
sub verify_groupname {
    my ($groupname, $noerr) = @_;

    if ($groupname !~ m/^[A-Za-z0-9\.\-_]+$/) {

	die "group name '$groupname' contains invalid characters\n" if !$noerr;

	return undef;
    }
    
    return $groupname;
}

PVE::JSONSchema::register_format('pve-roleid', \&verify_rolename);
sub verify_rolename {
    my ($rolename, $noerr) = @_;

    if ($rolename !~ m/^[A-Za-z0-9\.\-_]+$/) {

	die "role name '$rolename' contains invalid characters\n" if !$noerr;

	return undef;
    }
    
    return $rolename;
}

PVE::JSONSchema::register_format('pve-poolid', \&verify_groupname);
sub verify_poolname {
    my ($poolname, $noerr) = @_;

    if ($poolname !~ m/^[A-Za-z0-9\.\-_]+$/) {

	die "pool name '$poolname' contains invalid characters\n" if !$noerr;

	return undef;
    }
    
    return $poolname;
}

PVE::JSONSchema::register_format('pve-priv', \&verify_privname);
sub verify_privname {
    my ($priv, $noerr) = @_;

    if (!$valid_privs->{$priv}) {
	die "invalid priviledge '$priv'\n" if !$noerr;

	return undef;
    }
    
    return $priv;
}

sub userconfig_force_defaults {
    my ($cfg) = @_;

    foreach my $r (keys %$special_roles) {
	$cfg->{roles}->{$r} = $special_roles->{$r};
    }

    # fixme: remove 'root' group (not required)?

    # add root user 
    #$cfg->{users}->{'root@pam'}->{enable} = 1;
}

sub parse_user_config {
    my ($filename, $raw) = @_;

    my $cfg = {};

    userconfig_force_defaults($cfg);

    while ($raw && $raw =~ s/^(.*?)(\n|$)//) {
	my $line = $1;

	next if $line =~ m/^\s*$/; # skip empty lines

	my @data;

	foreach my $d (split (/:/, $line)) {
	    $d =~ s/^\s+//; 
	    $d =~ s/\s+$//;
	    push @data, $d
	}

	my $et = shift @data;

	if ($et eq 'user') {
	    my ($user, $enable, $expire, $firstname, $lastname, $email, $comment, $keys, $duosecurity, $duosecurity_username) = @data;

	    my (undef, undef, $realm) = PVE::Auth::Plugin::verify_username($user, 1);
	    if (!$realm) {
		warn "user config - ignore user '$user' - invalid user name\n";
		next;
	    }

	    $enable = $enable ? 1 : 0;
        $duosecurity = $duosecurity ? 1 : 0;

	    $expire = 0 if !$expire;

	    if ($expire !~ m/^\d+$/) {
		warn "user config - ignore user '$user' - (illegal characters in expire '$expire')\n";
		next;
	    }
	    $expire = int($expire);

	    #if (!verify_groupname ($group, 1)) {
	    #    warn "user config - ignore user '$user' - invalid characters in group name\n";
	    #    next;
	    #}

	    $cfg->{users}->{$user} = {
		enable => $enable,
        duosecurity => $duosecurity,
		# group => $group,
	    };
	    $cfg->{users}->{$user}->{firstname} = PVE::Tools::decode_text($firstname) if $firstname;
	    $cfg->{users}->{$user}->{lastname} = PVE::Tools::decode_text($lastname) if $lastname;
	    $cfg->{users}->{$user}->{email} = $email;
	    $cfg->{users}->{$user}->{comment} = PVE::Tools::decode_text($comment) if $comment;
	    $cfg->{users}->{$user}->{expire} = $expire;
	    # keys: allowed yubico key ids or oath secrets (base32 encoded)
	    $cfg->{users}->{$user}->{keys} = $keys if $keys;
        $cfg->{users}->{$user}->{duosecurity_username} = $duosecurity_username if $duosecurity_username;

	    #$cfg->{users}->{$user}->{groups}->{$group} = 1;
	    #$cfg->{groups}->{$group}->{$user} = 1;

	} elsif ($et eq 'group') {
	    my ($group, $userlist, $comment) = @data;

	    if (!verify_groupname($group, 1)) {
		warn "user config - ignore group '$group' - invalid characters in group name\n";
		next;
	    }

	    # make sure to add the group (even if there are no members)
	    $cfg->{groups}->{$group} = { users => {} } if !$cfg->{groups}->{$group};

	    $cfg->{groups}->{$group}->{comment} = PVE::Tools::decode_text($comment) if $comment;

	    foreach my $user (split_list($userlist)) {

		if (!PVE::Auth::Plugin::verify_username($user, 1)) {
		    warn "user config - ignore invalid group member '$user'\n";
		    next;
		}

		if ($cfg->{users}->{$user}) { # user exists 
		    $cfg->{users}->{$user}->{groups}->{$group} = 1;
		    $cfg->{groups}->{$group}->{users}->{$user} = 1;
		} else {
		    warn "user config - ignore invalid group member '$user'\n";
		}
	    }

	} elsif ($et eq 'role') {
	    my ($role, $privlist) = @data;
		
	    if (!verify_rolename($role, 1)) {
		warn "user config - ignore role '$role' - invalid characters in role name\n";
		next;
	    }

	    # make sure to add the role (even if there are no privileges)
	    $cfg->{roles}->{$role} = {} if !$cfg->{roles}->{$role};

	    foreach my $priv (split_list($privlist)) {
		if (defined ($valid_privs->{$priv})) {
		    $cfg->{roles}->{$role}->{$priv} = 1;
		} else {
		    warn "user config - ignore invalid priviledge '$priv'\n";
		} 
	    }
	    
	} elsif ($et eq 'acl') {
	    my ($propagate, $pathtxt, $uglist, $rolelist) = @data;

	    if (my $path = normalize_path($pathtxt)) {
		foreach my $role (split_list($rolelist)) {
			
		    if (!verify_rolename($role, 1)) {
			warn "user config - ignore invalid role name '$role' in acl\n";
			next;
		    }

		    foreach my $ug (split_list($uglist)) {
			if ($ug =~ m/^@(\S+)$/) {
			    my $group = $1;
			    if ($cfg->{groups}->{$group}) { # group exists 
				$cfg->{acl}->{$path}->{groups}->{$group}->{$role} = $propagate;
			    } else {
				warn "user config - ignore invalid acl group '$group'\n";
			    }
			} elsif (PVE::Auth::Plugin::verify_username($ug, 1)) {
			    if ($cfg->{users}->{$ug}) { # user exists 
				$cfg->{acl}->{$path}->{users}->{$ug}->{$role} = $propagate;
			    } else {
				warn "user config - ignore invalid acl member '$ug'\n";
			    }
			} else {
			    warn "user config - invalid user/group '$ug' in acl\n";
			}
		    }
		}
	    } else {
		warn "user config - ignore invalid path in acl '$pathtxt'\n";
	    }
	} elsif ($et eq 'pool') {
	    my ($pool, $comment, $vmlist, $storelist) = @data;

	    if (!verify_poolname($pool, 1)) {
		warn "user config - ignore pool '$pool' - invalid characters in pool name\n";
		next;
	    }

	    # make sure to add the pool (even if there are no members)
	    $cfg->{pools}->{$pool} = { vms => {}, storage => {} } if !$cfg->{pools}->{$pool};

	    $cfg->{pools}->{$pool}->{comment} = PVE::Tools::decode_text($comment) if $comment;

	    foreach my $vmid (split_list($vmlist)) {
		if ($vmid !~ m/^\d+$/) {
		    warn "user config - ignore invalid vmid '$vmid' in pool '$pool'\n";
		    next;
		}
		$vmid = int($vmid);

		if ($cfg->{vms}->{$vmid}) {
		    warn "user config - ignore duplicate vmid '$vmid' in pool '$pool'\n";
		    next;
		}

		$cfg->{pools}->{$pool}->{vms}->{$vmid} = 1;
		    
		# record vmid ==> pool relation
		$cfg->{vms}->{$vmid} = $pool;
	    }

	    foreach my $storeid (split_list($storelist)) {
		if ($storeid !~ m/^[a-z][a-z0-9\-\_\.]*[a-z0-9]$/i) {
		    warn "user config - ignore invalid storage '$storeid' in pool '$pool'\n";
		    next;
		}
		$cfg->{pools}->{$pool}->{storage}->{$storeid} = 1;
	    }
	} else {
	    warn "user config - ignore config line: $line\n";
	}
    }

    userconfig_force_defaults($cfg);

    return $cfg;
}

sub write_user_config {
    my ($filename, $cfg) = @_;

    my $data = '';

    foreach my $user (keys %{$cfg->{users}}) {
	my $d = $cfg->{users}->{$user};
	my $firstname = $d->{firstname} ? PVE::Tools::encode_text($d->{firstname}) : '';
	my $lastname = $d->{lastname} ? PVE::Tools::encode_text($d->{lastname}) : '';
	my $email = $d->{email} || '';
	my $comment = $d->{comment} ? PVE::Tools::encode_text($d->{comment}) : '';
	my $expire = int($d->{expire} || 0);
	my $enable = $d->{enable} ? 1 : 0;
	my $keys = $d->{keys} ? $d->{keys} : '';
    my $duosecurity = $d->{duosecurity} ? 1 : 0;
    my $duosecurity_username = $d->{duosecurity_username} || '';
	$data .= "user:$user:$enable:$expire:$firstname:$lastname:$email:$comment:$keys:$duosecurity:$duosecurity_username:\n";
    }

    $data .= "\n";

    foreach my $group (keys %{$cfg->{groups}}) {
	my $d = $cfg->{groups}->{$group};
	my $list = join (',', keys %{$d->{users}});
	my $comment = $d->{comment} ? PVE::Tools::encode_text($d->{comment}) : '';	
	$data .= "group:$group:$list:$comment:\n";
    }

    $data .= "\n";

    foreach my $pool (keys %{$cfg->{pools}}) {
	my $d = $cfg->{pools}->{$pool};
	my $vmlist = join (',', keys %{$d->{vms}});
	my $storelist = join (',', keys %{$d->{storage}});
	my $comment = $d->{comment} ? PVE::Tools::encode_text($d->{comment}) : '';	
	$data .= "pool:$pool:$comment:$vmlist:$storelist:\n";
    }

    $data .= "\n";

    foreach my $role (keys %{$cfg->{roles}}) {
	next if $special_roles->{$role};

	my $d = $cfg->{roles}->{$role};
	my $list = join (',', keys %$d);
	$data .= "role:$role:$list:\n";
    }

    $data .= "\n";

    foreach my $path (sort keys %{$cfg->{acl}}) {
	my $d = $cfg->{acl}->{$path};

	my $ra = {};

	foreach my $group (keys %{$d->{groups}}) {
	    my $l0 = '';
	    my $l1 = '';
	    foreach my $role (sort keys %{$d->{groups}->{$group}}) {
		my $propagate = $d->{groups}->{$group}->{$role};
		if ($propagate) {
		    $l1 .= ',' if $l1;
		    $l1 .= $role;
		} else {
		    $l0 .= ',' if $l0;
		    $l0 .= $role;
		}
	    }
	    $ra->{0}->{$l0}->{"\@$group"} = 1 if $l0;
	    $ra->{1}->{$l1}->{"\@$group"} = 1 if $l1;
	}

	foreach my $user (keys %{$d->{users}}) {
	    # no need to save, because root is always 'Administartor'
	    next if $user eq 'root@pam'; 

	    my $l0 = '';
	    my $l1 = '';
	    foreach my $role (sort keys %{$d->{users}->{$user}}) {
		my $propagate = $d->{users}->{$user}->{$role};
		if ($propagate) {
		    $l1 .= ',' if $l1;
		    $l1 .= $role;
		} else {
		    $l0 .= ',' if $l0;
		    $l0 .= $role;
		}
	    }
	    $ra->{0}->{$l0}->{$user} = 1 if $l0;
	    $ra->{1}->{$l1}->{$user} = 1 if $l1;
	}

	foreach my $rolelist (sort keys %{$ra->{0}}) {
	    my $uglist = join (',', keys %{$ra->{0}->{$rolelist}});
	    $data .= "acl:0:$path:$uglist:$rolelist:\n";
	}
	foreach my $rolelist (sort keys %{$ra->{1}}) {
	    my $uglist = join (',', keys %{$ra->{1}->{$rolelist}});
	    $data .= "acl:1:$path:$uglist:$rolelist:\n";
	}
    }

    return $data;
}

sub roles {
    my ($cfg, $user, $path) = @_;

    # NOTE: we do not consider pools here. 
    # You need to use $rpcenv->roles() instead if you want that.

    return 'Administrator' if $user eq 'root@pam'; # root can do anything

    my $perm = {};

    foreach my $p (sort keys %{$cfg->{acl}}) {
	my $final = ($path eq $p);

	next if !(($p eq '/') || $final || ($path =~ m|^$p/|));

	my $acl = $cfg->{acl}->{$p};

	#print "CHECKACL $path $p\n";
	#print "ACL $path = " . Dumper ($acl);

	if (my $ri = $acl->{users}->{$user}) {
	    my $new;
	    foreach my $role (keys %$ri) {
		my $propagate = $ri->{$role};
		if ($final || $propagate) {
		    #print "APPLY ROLE $p $user $role\n";
		    $new = {} if !$new;
		    $new->{$role} = 1;
		}
	    }
	    if ($new) {
		$perm = $new; # overwrite previous settings
		next; # user privs always override group privs
	    }
	}

	my $new;
	foreach my $g (keys %{$acl->{groups}}) {
	    next if !$cfg->{groups}->{$g}->{users}->{$user};
	    if (my $ri = $acl->{groups}->{$g}) {
		foreach my $role (keys %$ri) {
		    my $propagate = $ri->{$role};
		    if ($final || $propagate) {
			#print "APPLY ROLE $p \@$g $role\n";
			$new = {} if !$new;
			$new->{$role} = 1;
		    }
		}
	    }
	}
	if ($new) {
	    $perm = $new; # overwrite previous settings
	    next;
	}
    }

    return ('NoAccess') if defined ($perm->{NoAccess});
    #return () if defined ($perm->{NoAccess});
   
    #print "permission $user $path = " . Dumper ($perm);

    my @ra = keys %$perm;

    #print "roles $user $path = " . join (',', @ra) . "\n";

    return @ra;
}
    
sub permission {
    my ($cfg, $user, $path) = @_;

    $user = PVE::Auth::Plugin::verify_username($user, 1);
    return {} if !$user;

    my @ra = roles($cfg, $user, $path);
    
    my $privs = {};

    foreach my $role (@ra) {
	if (my $privset = $cfg->{roles}->{$role}) {
	    foreach my $p (keys %$privset) {
		$privs->{$p} = 1;
	    }
	}
    }

    #print "priviledges $user $path = " . Dumper ($privs);

    return $privs;
}

sub check_permissions {
    my ($username, $path, $privlist) = @_;

    $path = normalize_path($path);
    my $usercfg = cfs_read_file('user.cfg');
    my $perm = permission($usercfg, $username, $path);

    foreach my $priv (split_list($privlist)) {
	return undef if !$perm->{$priv};
    };

    return 1;
}

sub add_vm_to_pool {
    my ($vmid, $pool) = @_;

    my $addVMtoPoolFn = sub {
	my $usercfg = cfs_read_file("user.cfg");
	if (my $data = $usercfg->{pools}->{$pool}) {
	    $data->{vms}->{$vmid} = 1;
	    $usercfg->{vms}->{$vmid} = $pool;
	    cfs_write_file("user.cfg", $usercfg);
	}
    };

    lock_user_config($addVMtoPoolFn, "can't add VM $vmid to pool '$pool'");
}

sub remove_vm_from_pool {
    my ($vmid) = @_;
    
    my $delVMfromPoolFn = sub {
	my $usercfg = cfs_read_file("user.cfg");
	if (my $pool = $usercfg->{vms}->{$vmid}) {
	    if (my $data = $usercfg->{pools}->{$pool}) {
		delete $data->{vms}->{$vmid};
		delete $usercfg->{vms}->{$vmid};
		cfs_write_file("user.cfg", $usercfg);
	    }
	}
    };

    lock_user_config($delVMfromPoolFn, "pool cleanup for VM $vmid failed");
}

# experimental code for yubico OTP verification

sub yubico_compute_param_sig {
    my ($param, $api_key) = @_;

    my $paramstr = '';
    foreach my $key (sort keys %$param) {
	$paramstr .= '&' if $paramstr;
	$paramstr .= "$key=$param->{$key}";
    }

    my $sig = uri_escape(encode_base64(Digest::HMAC_SHA1::hmac_sha1($paramstr, decode_base64($api_key || '')), ''));

    return ($paramstr, $sig);
}

sub yubico_verify_otp {
    my ($otp, $keys, $url, $api_id, $api_key, $proxy) = @_;

    die "yubico: missing password\n" if !defined($otp);
    die "yubico: missing API ID\n" if !defined($api_id);
    die "yubico: missing API KEY\n" if !defined($api_key);
    die "yubico: no associated yubico keys\n" if $keys =~ m/^\s+$/; 

    die "yubico: wrong OTP lenght\n" if (length($otp) < 32) || (length($otp) > 48);

    # we always use http, because https cert verification always make problem, and
    # some proxies does not work with https.

    $url = 'http://api2.yubico.com/wsapi/2.0/verify' if !defined($url);
    
    my $params = {
	nonce =>  Digest::HMAC_SHA1::hmac_sha1_hex(time(), rand()),
	id => $api_id,
	otp => uri_escape($otp),
	timestamp => 1,
    };

    my ($paramstr, $sig) = yubico_compute_param_sig($params, $api_key);

    $paramstr .= "&h=$sig" if $api_key;

    my $req = HTTP::Request->new('GET' => "$url?$paramstr");

    my $ua = LWP::UserAgent->new(protocols_allowed => ['http'], timeout => 30);

    if ($proxy) {
	$ua->proxy(['http'], $proxy);
    } else {
	$ua->env_proxy;
    }

    my $response = $ua->request($req);
    my $code = $response->code;

    if ($code != 200) {
	my $msg = $response->message || 'unknown';
	die "Invalid response from server: $code $msg\n";
    }

    my $raw = $response->decoded_content;

    my $result = {};
    foreach my $kvpair (split(/\n/, $raw)) {
	chomp $kvpair;
	if($kvpair =~ /^\S+=/) {
	    my ($k, $v) = split(/=/, $kvpair, 2);
	    $v =~ s/\s//g;
	    $result->{$k} = $v;
        }
    }

    my $rsig = $result->{h};
    delete $result->{h};

    if ($api_key) {
	my ($datastr, $vsig) = yubico_compute_param_sig($result, $api_key);
	$vsig = uri_unescape($vsig);
	die "yubico: result signature verification failed\n" if $rsig ne $vsig;
    }

    die "yubico auth failed: $result->{status}\n" if $result->{status} ne 'OK';

    my $publicid = $result->{publicid} = substr(lc($result->{otp}), 0, 12);

    my $found;
    foreach my $k (PVE::Tools::split_list($keys)) {
	if ($k eq $publicid) {
	    $found = 1;
	    last;
	}
    }

    die "yubico auth failed: key does not belong to user\n" if !$found;

    return $result;
}

sub oath_verify_otp {
    my ($otp, $keys, $step, $digits) = @_;

    die "oath: missing password\n" if !defined($otp);
    die "oath: no associated oath keys\n" if $keys =~ m/^\s+$/; 

    $step = 30 if !$step;
    $digits = 6 if !$digits;

    my $found;

    my $parser = sub {
	my $line = shift;

	if ($line =~ m/^\d{6}$/) {
	    $found = 1 if $otp eq $line;
	}
    };

    foreach my $k (PVE::Tools::split_list($keys)) {
	# Note: we generate 3 values to allow small time drift
	my $now = localtime(time() - $step);
	my $cmd = ['oathtool', '--totp', '--digits', $digits, '-N', $now, '-s', $step, '-w', '2', '-b', $k];
	eval { run_command($cmd, outfunc => $parser, errfunc => sub {}); };
	last if $found;
    }

    die "oath auth failed\n" if !$found;
}

1;

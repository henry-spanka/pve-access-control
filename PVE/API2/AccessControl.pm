package PVE::API2::AccessControl;

use strict;
use warnings;

use PVE::Exception qw(raise raise_perm_exc);
use PVE::SafeSyslog;
use PVE::RPCEnvironment;
use PVE::Cluster qw(cfs_read_file);
use PVE::RESTHandler;
use PVE::AccessControl;
use PVE::JSONSchema qw(get_standard_option);
use PVE::API2::Domains;
use PVE::API2::User;
use PVE::API2::Group;
use PVE::API2::Role;
use PVE::API2::ACL;
use PVE::DuoSecurity;
use URI::Escape;
use PVE::INotify;

use base qw(PVE::RESTHandler);

__PACKAGE__->register_method ({
    subclass => "PVE::API2::User",  
    path => 'users',
});

__PACKAGE__->register_method ({
    subclass => "PVE::API2::Group",  
    path => 'groups',
});

__PACKAGE__->register_method ({
    subclass => "PVE::API2::Role",  
    path => 'roles',
});

__PACKAGE__->register_method ({
    subclass => "PVE::API2::ACL",  
    path => 'acl',
});

__PACKAGE__->register_method ({
    subclass => "PVE::API2::Domains",  
    path => 'domains',
});

__PACKAGE__->register_method ({
    name => 'index', 
    path => '', 
    method => 'GET',
    description => "Directory index.",
    permissions => { 
	user => 'all',
    },
    parameters => {
    	additionalProperties => 0,
	properties => {},
    },
    returns => {
	type => 'array',
	items => {
	    type => "object",
	    properties => {
		subdir => { type => 'string' },
	    },
	},
	links => [ { rel => 'child', href => "{subdir}" } ],
    },
    code => sub {
	my ($param) = @_;
    
	my $res = [];

	my $ma = __PACKAGE__->method_attributes();

	foreach my $info (@$ma) {
	    next if !$info->{subclass};

	    my $subpath = $info->{match_re}->[0];

	    push @$res, { subdir => $subpath };
	}

	push @$res, { subdir => 'ticket' };
	push @$res, { subdir => 'password' };

	return $res;
    }});


my $verify_auth = sub {
    my ($rpcenv, $username, $pw_or_ticket, $otp, $path, $privs) = @_;

    my $normpath = PVE::AccessControl::normalize_path($path);

    my $ticketuser;
    if (($ticketuser = PVE::AccessControl::verify_ticket($pw_or_ticket, 1)) &&
	($ticketuser eq $username)) {
	# valid ticket
    } elsif (PVE::AccessControl::verify_vnc_ticket($pw_or_ticket, $username, $normpath, 1)) {
	# valid vnc ticket
    } else {
	$username = PVE::AccessControl::authenticate_user($username, $pw_or_ticket, $otp);
    }

    my $privlist = [ PVE::Tools::split_list($privs) ];
    if (!($normpath && scalar(@$privlist) && $rpcenv->check($username, $normpath, $privlist))) {
	die "no permission ($path, $privs)\n";
    }

    return { username => $username };
};

my $create_ticket = sub {
    my ($rpcenv, $username, $pw_or_ticket, $otp) = @_;

    my $ticketuser;
    if (($ticketuser = PVE::AccessControl::verify_ticket($pw_or_ticket, 1)) &&
	($ticketuser eq 'root@pam' || $ticketuser eq $username)) {
	# valid ticket. Note: root@pam can create tickets for other users
    } else {
	$username = PVE::AccessControl::authenticate_user($username, $pw_or_ticket, $otp);
    }

    my $ticket = PVE::AccessControl::assemble_ticket($username);
    my $csrftoken = PVE::AccessControl::assemble_csrf_prevention_token($username);

    return {
	ticket => $ticket,
	username => $username,
	CSRFPreventionToken => $csrftoken,
    };
};

my $compute_api_permission = sub {
    my ($rpcenv, $authuser) = @_;

    my $usercfg = $rpcenv->{user_cfg};

    my $nodelist = PVE::Cluster::get_nodelist();
    my $vmlist = PVE::Cluster::get_vmlist() || {};
    my $idlist = $vmlist->{ids} || {};

    my $cfg = PVE::Storage::config();
    my @sids =  PVE::Storage::storage_ids ($cfg);

    my $res = {
	vms => {},
	storage => {},
	access => {},
	nodes => {},
	dc => {},
    };

    my $extract_vm_caps = sub {
	my ($path) = @_;
	
	my $perm = $rpcenv->permissions($authuser, $path);
	foreach my $priv (keys %$perm) {
	    next if !($priv eq 'Permissions.Modify' || $priv =~ m/^VM\./);
	    $res->{vms}->{$priv} = 1;	
	}
    };

    foreach my $pool (keys %{$usercfg->{pools}}) {
	&$extract_vm_caps("/pool/$pool");
    }

    foreach my $vmid (keys %$idlist, '__phantom__') {
	&$extract_vm_caps("/vms/$vmid");
    }

    foreach my $storeid (@sids, '__phantom__') {
	my $perm = $rpcenv->permissions($authuser, "/storage/$storeid");
	foreach my $priv (keys %$perm) {
	    next if !($priv eq 'Permissions.Modify' || $priv =~ m/^Datastore\./);
	    $res->{storage}->{$priv} = 1;
	}
    }

    foreach my $path (('/access/groups')) {
	my $perm = $rpcenv->permissions($authuser, $path);
	foreach my $priv (keys %$perm) {
	    next if $priv !~ m/^(User|Group)\./;
	    $res->{access}->{$priv} = 1;
	}
    }

    foreach my $group (keys %{$usercfg->{users}->{$authuser}->{groups}}, '__phantom__') {
	my $perm = $rpcenv->permissions($authuser, "/access/groups/$group");
	if ($perm->{'User.Modify'}) {
	    $res->{access}->{'User.Modify'} = 1;
	}
    }

    foreach my $node (@$nodelist) {
	my $perm = $rpcenv->permissions($authuser, "/nodes/$node");
	foreach my $priv (keys %$perm) {
	    next if $priv !~ m/^Sys\./;
	    $res->{nodes}->{$priv} = 1;
	}
    }

    my $perm = $rpcenv->permissions($authuser, "/");
    $res->{dc}->{'Sys.Audit'} = 1 if $perm->{'Sys.Audit'};

    return $res;
};

__PACKAGE__->register_method ({
    name => 'get_ticket', 
    path => 'ticket', 
    method => 'GET',
    permissions => { user => 'world' },
    description => "Dummy. Useful for formaters which want to priovde a login page.",
    parameters => {
	additionalProperties => 0,
    },
    returns => { type => "null" },
    code => sub { return undef; }});
  
__PACKAGE__->register_method ({
    name => 'create_ticket', 
    path => 'ticket', 
    method => 'POST',
    permissions => { 
	description => "You need to pass valid credientials.",
	user => 'world' 
    },
    protected => 1, # else we can't access shadow files
    description => "Create or verify authentication ticket.",
    parameters => {
	additionalProperties => 0,
	properties => {
	    username => {
		description => "User name",
		type => 'string',
		maxLength => 64,
	    },
	    realm =>  get_standard_option('realm', {
		description => "You can optionally pass the realm using this parameter. Normally the realm is simply added to the username <username>\@<relam>.",
		optional => 1}),
	    password => { 
		description => "The secret password. This can also be a valid ticket.",
		type => 'string',
	    },
	    otp => {
		description => "One-time password for Two-factor authentication.",
		type => 'string',
		optional => 1,
	    },
	    path => {
		description => "Verify ticket, and check if user have access 'privs' on 'path'",
		type => 'string',
		requires => 'privs',
		optional => 1,
		maxLength => 64,
	    },
	    privs => { 
		description => "Verify ticket, and check if user have access 'privs' on 'path'",
		type => 'string' , format => 'pve-priv-list',
		requires => 'path',
		optional => 1,
		maxLength => 64,
	    },
        duoauthmethod => {
            description => "Duo Auth method. Device ID and method need to be seperated with an underscore.",
            type => 'string',
            optional => 1
        },
        duo_passcode => {
            description => "Duo pass code. Authmethod needs to be passcode",
            type => 'integer',
            optional => 1
        }
	}
    },
    returns => {
	type => "object",
	properties => {
	    username => { type => 'string' },
	    ticket => { type => 'string', optional => 1},
	    CSRFPreventionToken => { type => 'string', optional => 1 },
	}
    },
    code => sub {
	my ($param) = @_;
    
	my $username = $param->{username};
	$username .= "\@$param->{realm}" if $param->{realm};

	my $rpcenv = PVE::RPCEnvironment::get();

	my $res;

    my $usercfg = cfs_read_file("user.cfg");

    eval {
        # test if user exists and is enabled
        $rpcenv->check_user_enabled($username);

        if ($param->{path} && $param->{privs}) {
            $res = &$verify_auth($rpcenv, $username, $param->{password}, $param->{otp},
                     $param->{path}, $param->{privs});
        } else {
            $res = &$create_ticket($rpcenv, $username, $param->{password}, $param->{otp});
        }
    };
    if (my $err = $@) {
        my $clientip = $rpcenv->get_client_ip() || '';
        syslog('err', "authentication failure; rhost=$clientip user=$username msg=$err");
        # do not return any info to prevent user enumeration attacks
        die PVE::Exception->new("authentication failure\n", code => 401);
    }

    my $ticketinvalid = 1;

    eval {
        PVE::AccessControl::verify_ticket($param->{password});
    };
    if (!$@) {
        $ticketinvalid = 0;
    }

    if($usercfg->{users}->{$username}->{duosecurity} && $ticketinvalid eq 1) {

        my $duousername = $usercfg->{users}->{$username}->{duosecurity_username} || $username;

        my $duo_options = PVE::Cluster::cfs_read_file('duosecurity.cfg');

        my $duoapi = new PVE::DuoSecurity($duo_options->{integration_key},
                $duo_options->{secret_key},
                $duo_options->{hostname}
        );

        $duoapi->json_api_call('GET', '/auth/v2/check', {});

        my $duoresult;

        if($param->{duoauthmethod}) {
            if($param->{duoauthmethod} eq 'passcode' && $param->{duo_passcode}) {
                $duoresult = $duoapi->json_api_call('POST', '/auth/v2/auth', {
                    ipaddr => $rpcenv->get_client_ip() || '',
                    username => $duousername,
                    factor => 'passcode',
                    passcode => $param->{duo_passcode}
                });
            } elsif($param->{duoauthmethod} =~ /^([a-zA-Z\d]+)_(push|phone|sms)$/s) {
                if($2 eq 'push') {

                    my $realusername = uri_escape($username);
                    my $nodename = uri_escape(`hostname -f` || PVE::INotify::nodename());

                    $duoresult = $duoapi->json_api_call('POST', '/auth/v2/auth', {
                        ipaddr => $rpcenv->get_client_ip() || '',
                        username => $duousername,
                        factor => $2,
                        device => $1,
                        pushinfo => "Real%20Username=${realusername}&Node%20Name=${nodename}"
                    });
                } else {
                    $duoresult = $duoapi->json_api_call('POST', '/auth/v2/auth', {
                        ipaddr => $rpcenv->get_client_ip() || '',
                        username => $duousername,
                        factor => $2,
                        device => $1
                    });
                }
            } else {
                die PVE::Exception->new("Duo Authentication failure\n", code => 401);
            }

            if($duoresult->{result} ne 'allow') {
                die PVE::Exception->new("Duo Authentication failure: $duoresult->{status_msg}\n", code => 401);
            }

        } else {

            my $duoresponse = $duoapi->json_api_call('POST', '/auth/v2/preauth', {
                ipaddr => $rpcenv->get_client_ip() || '',
                username => $duousername
                }
            );

            $duoresponse->{username} = $username;
            $duoresponse->{duosecurity} = 1;
            return $duoresponse;
        }
    }

	$res->{cap} = &$compute_api_permission($rpcenv, $username);

	PVE::Cluster::log_msg('info', 'root@pam', "successful auth for user '$username'");

	return $res;
    }});

__PACKAGE__->register_method ({
    name => 'change_passsword', 
    path => 'password', 
    method => 'PUT',
    permissions => { 
	description => "Each user is allowed to change his own password. A user can change the password of another user if he has 'Realm.AllocateUser' (on the realm of user <userid>) and 'User.Modify' permission on /access/groups/<group> on a group where user <userid> is member of.",
	check => [ 'or', 
		   ['userid-param', 'self'],
		   [ 'and',
		     [ 'userid-param', 'Realm.AllocateUser'],
		     [ 'userid-group', ['User.Modify']]
		   ]
	    ],
    },
    protected => 1, # else we can't access shadow files
    description => "Change user password.",
    parameters => {
	additionalProperties => 0,
	properties => {
	    userid => get_standard_option('userid'),
	    password => { 
		description => "The new password.",
		type => 'string',
		minLength => 5, 
		maxLength => 64,
	    },
	}
    },
    returns => { type => "null" },
    code => sub {
	my ($param) = @_;

	my $rpcenv = PVE::RPCEnvironment::get();
	my $authuser = $rpcenv->get_user();

	my ($userid, $ruid, $realm) = PVE::AccessControl::verify_username($param->{userid});

	$rpcenv->check_user_exist($userid);

	if ($authuser eq 'root@pam') {
	    # OK - root can change anything
	} else {
	    if ($authuser eq $userid) {
		$rpcenv->check_user_enabled($userid);
		# OK - each user can change its own password
	    } else {
		# only root may change root password
		raise_perm_exc() if $userid eq 'root@pam';
		# do not allow to change system user passwords
		raise_perm_exc() if $realm eq 'pam';
	    }
	}

	PVE::AccessControl::domain_set_password($realm, $ruid, $param->{password});

	PVE::Cluster::log_msg('info', 'root@pam', "changed password for user '$userid'");

	return undef;
    }});

1;

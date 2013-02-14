#!/usr/bin/perl

#use strict;
use DBI();
use Socket;	
use Net::DNS;
use File::Copy;
use Time::HiRes qw(gettimeofday);

#use Text::FIGlet;

#perl -MCPAN -e 'install Text::Figlet'
#cp into /usr/lib/perl5/site_perl/5.8.0/Text 

## Perl ESMTPD server (Nov 2002)

## Copyright (C) 2002, John Fields
## Under the terms of the BSD License

## perl esmtp server
## supports:
##  AUTH LOGIN and PLAIN authentication -- single password for site
##  MySQL interface to Spammenot databases
##  valid mx on mail from: <address> check
##  bounce null subject, null message
##  -- anything you want to add -- it's just perl
##
## see http://perl-esmtpd.sourceforge.net
##
#  (interesting sites)
# http://www.tneoh.zoneit.com/perl/SendMail/2.0/
#http://cr.yp.to/mail.html
## Known bugs:
## Log rolling is not implemented yet.

#configuration items

$version = '0.33';
#.31 = auto auth if from experttool
#.32 = fix broken logging
#.33 = added missing allowed-characters to the email local rules

$mydebuglevel=3;## Interactive debugger (note, incoming email addresses can over ride this)
				## 0 = none or quiet
				## 1 = normal - startup, errors and shutdown
				## 2 = normal + more setup details
				## 3 = normal + individual transaction result
				## 9 = EVERYTHING!!!

$AudioPlay=0;			## Play the sound files?  0=no, 1=yes

$me=                              ## your default host name
 'spammenot.com';     

#$user = 'nobody';					## who daemon runs as

$db_host = 'localhost';
$db_port = '3306';
$db_name = 'spammenot';
$db_user = '';
$db_pass = '';

$max_recipients = 20 ;	# can be changed when a user AUTHs, as we trust them now.
$MRBLG = 5 ;			# max_recipient_bad_local_guesses to catch directory attacks, trolling for addresses

$PID_file = "/var/run/spammenot_smtpd_$port.pid";	## let outside world know where you are

$relays='';                          ## relaying is allowed for these hosts
# '10.|127.0.0.1';          

$log=                             ## your log file location
 '/var/log/spammenot_smtpd.log';         

my $fName = "smtp_$$.log";	# $$ is the process ID
my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)=localtime(time);
$year += 1900;
my @abbr = qw( Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec );  # To be used with $mon which is month 0-11
my $msglog = "/var/log/spammenot/$year-$abbr[$mon]"; ## your debug msg file location
if(directory_OK("$msglog")) {
   $msglog .= "/$fName";  ## your debug msg file location
} else{
   die "Cannot create log file!";
   }

my $session_log = "";
	open(MSG_TXT,">>$msglog");
	select MSG_TXT; $|=1;					# make unbuffered
	&msg_txt("**** -00> Starting new run in $year");


$tmp='/srv/email/_tmp';
$spool_dir='/srv/email/_spool';	## where outbound emails are created

# the maildir parent directory
# /domain/user/new/ is added to it
$base_maildir='/srv/email';

$timeout = 20;				# if there is no activity for xx seconds, dump the caller


#$smallestvirus=2500;              ## size must be greater than this for viruscheck to run

#$viruscheck='/usr/users/checkvirus.sh';     ## adjust your antivirus settings here

## end of configuration stuff

#$relays=~s/\./\\./g; # quote the dots.
#$local_domains=~s/\./\\./g;
#$localrelays=~s/\./\\./g;

&msg_txt("Program started...");

sub output_txt {
	print STDOUT "@_\r\n";					## print to STDOUT, usually the socket file handle

	# Save all loggable	stuff to a variable, so	it can be optionally output	
	if($mydebuglevel) {
		$session_log .=	"srv: $p\n";
	}

	if($mydebuglevel>=2) {
		my $time=localtime;
		print MSG_TXT "$time $$ srv: @_\n";
	}

	alarm $timeout;	
}

sub input_txt {
	if($mydebuglevel>=2) {
		my $time=localtime;
		my $temp = shift(@_);
		$temp =~ s/\r/\(cr\)/g;		## if there is a carriage return, change it
		$temp =~ s/\n/\(lf\)/g;		## if there is a line feed, change it

		print MSG_TXT "$time $$ clt: $temp\n";
	}

	# Save all loggable	stuff to a variable, so	it can be optionally output	
	$session_log .=	"clt: $temp\n";

} #End input_txt

$SIG{ALRM} = sub {
	# flush the buffers, MySQL write, etc.
	&msg_txt("Alarm: $timeout sec timer expired, exiting");
	&log_session;
	die "inactivity timeout\n"
	};



#>-------------------------------------------
$SIG{INT} = \&shut_it_all_down;
$SIG{TERM} = \&shut_it_all_down;
$SIG{QUIT} = \&shut_it_all_down;


## read 'server' or inetd mode
#$_=shift(@ARGV); $_="\L$_";	## put CMD line args into STDIN, then convert to lower case

#&write_PID;

print MSG_TXT "\n\n";

select(STDOUT);$|=1;

&server;
&session;
&shut_it_all_down("normal");
exit;

#>----------- Shows over, all is subroutines after this -----------

sub shut_it_all_down {
 ## called on INT to clean up a bit
 my $why = shift;
 # $client = shift;

 $dbh->disconnect();
 #unlink $PID_file;
 &msg_txt("Exiting normally due to $why");
 # If we wanted to send some text out, do like this die 'Exiting Normally on INT';
 print "byebye\n";
 exit;
}

sub SockData($){
	my $theirsockaddr	= getpeername(STDIN);
	my ($port, $iaddr)	= unpack_sockaddr_in($theirsockaddr);
	my $theirhostname	= gethostbyaddr($iaddr, AF_INET);
	my $theirstraddr	= inet_ntoa($iaddr);
	return $theirhostname,$theirstraddr;
} #end of SockData



sub server {

	&msg_txt("Inside server, connecting to mySQL - fingers crossed");
	
	#======================= [ open_dbi ] =======================
	# Connect to the requested server, otherwise dont start the daemon(s)
	# http://perl.about.com/library/weekly/aa090803a.htm
	
	$dbh = DBI->connect("DBI:mysql:$db_name:$db_host","$db_user","$db_pass",{'RaiseError' => 1});
	#======================= [ open_dbi ] =======================
	
 	&msg_txt("MYSQL OK, loading domains ");
	$local_domains = makedomainlist($dbh);			# domains for whom we accept mail
	($remote_hostname,$remote_ip)=SockData(STDIN);	# get the IP address of STDIN
	&msg_txt("Connection from $remote_hostname($remote_ip)");

 if($user) {
  local($name,$passwd,$uid,$gid,$quota,$comment,$gcos,$dir,$shell,$expire) = getpwnam $user;
  &msg_txt("Moving to UID:$uid GID:$gid");
  ($>,$))=($uid,$gid);
  ($<,$()=($uid,$gid);
  }

	&msg_txt("Completed startup.");

} #end SERVER sub
# 	exit;


#>---------------------Forked code is here.....------------------
sub session {
 	#($dbh,$remote_ip) = @_;	# ip shortened from $remote_ip at the parent

	## local(@p,$sender->{fqaddress},$to,@a,$adr,$arg,$header,$hdone,$relay,$helo,%qfile,%maildir,$isspam,$quitnow); # Do we really need this?

	&output_txt("220-$me ESMTP super swimmy anti-spam version $version");
	&output_txt("220 Hi $remote_ip - $_");

	if ($remote_ip eq "70.242.101.113") {
			$auth = "rkobus";
			&output_txt("220 You are full YES! $auth");
			}
	elsif ($remote_ip eq "127.0.0.1") {
			$auth = "apache";
			&output_txt("220 You are full YES! $auth");
			}

	$quitnow=0;				# Initialize scalar to dump the smtp connection


## <STDIN> means the socket xinetd opened for us, so kindly
while(<STDIN>) {

 &input_txt("\(quit=$quitnow\) $_");		## Log all input from remote system here...
 if($quitnow) {&quit(); return;}
 if(length($_)>1000) {&quit(); return;}		## if line length greater than 1000 chars just quit.

 #s/\s+/ /g;
 #s/^ //;
 #s/ $//;

$this_user="";
$this_domain="";
$adr="";
 
if ($_=~/<([0-9a-zA-Z\.\-\_\:\+\@\#\=\!\$\%\&\'\*\/\?\^\`\{\}\|\~]+)(\@)([0-9a-zA-Z\.\-\_]+)>/io) {	#If a valid email address then parse
	$this_user=$1;				# take the user part (1st set of paren) as is
	$this_domain=$3;			# take the domain part (3rd set of paren)
	$adr=$2.$3;				# reconstruct the entire address, before new search kills $3!
	if ($this_user=~/:/) {			# does user part (1st set of paren) contain a semicolon?
		$this_user=~s/^.*://;}		# Trim off the pre-crap including the :
	if ($this_user=~/\+/) {			# does user part (1st set of paren) contain a plus sign?
		$this_user=~s/^.*\+//;}		# Trim off the pre-crap including the :
	$adr=$this_user.$adr;			# now prepend the correct(ed) user to @domain
	&msg_txt("-02> I preparsed: $this_user/$this_domain/$adr");
	}

 @p=split(' ',$_);				# split all parms into a hash, "space" delimted
 $arg=shift(@p);				# load just the first parameter
 $arg="\L$arg";					# make arg all lower case (\L=all following letters)

#>---------------------------------------------------------
  &msg_txt("-03> arg=$arg from=$adr, sender=$sender->{fqaddress}, auth=$auth");

#Maybe a good case statement?
if($arg eq 'helo') {&helo();}
elsif($arg eq 'ehlo') {&ehlo();}
elsif($arg eq 'auth') {&auth();}
elsif($arg eq 'rset') {&rset();}
elsif($arg eq 'noop') {&noop();}
elsif($arg eq 'help') {&help();}
elsif($arg eq 'mail') {&mail();}
elsif($arg eq 'rcpt') {&rcpt();}
elsif($arg eq 'data') {data($sender,$remote_ip,$auth,$spool_dir,$recipient_count,@recipients);}
elsif($arg eq 'vrfy') {&vrfy();}
elsif($arg eq 'quit') {&quit();}
else {
  &output_txt ("500 huu?? unknown command <$arg>");
  }

}#End of While
}#End of sub session

#>---------------------------------------------------------
 sub quit{
  &output_txt("221 bye");
} #End of quit


#>---------------------------------------------------------
sub helo {
   $helo=$p[0];
   &output_txt("250 $me");
} #End of helo


#>---------------------------------------------------------
sub ehlo {
  $helo=$p[0];
  &output_txt("250-$me supports:");
#  print "250-PIPELINING\r\n";
  &output_txt("250-AUTH=LOGIN PLAIN") unless $relay;	## for MS clients
  &output_txt("250-AUTH LOGIN PLAIN") unless $relay;	## The RFC way to spell it
  &output_txt("250 8BITMIME");

} #End of ehlo


#>---------------------------------------------------------
sub auth {
   $pw = "oooglymooglybiggahboo";	## set password to unique value

   if("\L$p[0]" eq 'plain') {
	@a=split("\000",base64($p[1]));
	&msg_txt("I see: $a[1]:$a[2]");		## prints their authorization in plain text

	if ((length($a[1])) >127) {
		 &output_txt("538 AUTH");
		 $quitnow=1;
		 return ;
		}		

	$sender = lookup4auth($a[1],$dbh);		## go get the password in file

		if("\L$a[2]" eq $sender->{pw}) {
		 $relay=1;
		 &output_txt("235 AUTH OK");
		 $auth=" auth:$a[1]; ";			## $auth now contains " jfields; "
		 $max_recipients = $sender->{max_recipients};
	
		} elsif($sender->{status} ne "OK") {
		 &output_txt("538 AUTH failed \(account on hold! call us!\)");
		 $quitnow=1;
	
		} else {
		 &msg_txt("I judge: 538 AUTHorization Failed \(dropping connection\)");
		 &output_txt("538 AUTH failed");
		 $quitnow=1;					## dump the connection on next WHILE
		} # end of PW if, also end of PLAIN section
	
   } elsif("\L$p[0]" eq 'login') {
	 if($p[1]) {
	  ## The client can go ahead and send the username on the same line as AUTH LOGIN,
	  ## and it looks like they did here
	  $a[1]=base64($p[1]);
	 } else {
	 ## OK, they didn't send the username, so ask for it in base64
	 &output_txt("334 VXNlcm5hbWU6");	# VXNlcm5hbWU6='Username:'
	 $_=<STDIN>;
	 &input_txt("$_");
	  $a[1]=base64($_);
	 }

	## http://makcoder.sourceforge.net/demo/base64.php
	## jfields@piglet.fieldsfamily.net='amZpZWxkc0BwaWdsZXQuZmllbGRzZmFtaWx5Lm5ldA0K'
	## quake3rani='cXVha2UzcmFuaQ=='

	&msg_txt("Passing in: $a[1]");		## prints their authorization in plain text
	$sender = lookup4auth($a[1],$dbh);		## go get the password in file
	&msg_txt("Passed out: $sender->{pw}");		## prints their authorization in plain text

	if($sender->{status} ne 'OK') {
	 &output_txt("538 AUTH failed \(account on hold! call us!\)");
	 $quitnow=1;
	 } else {
		&output_txt("334 UGFzc3dvcmQ6");	# UGFzc3dvcmQ6='Password:'
		$_=<STDIN>;
		&input_txt("$_");
		$a[2]=base64($_);
		if("\L$a[2]" eq $sender->{pw}) {
		 $relay=1;
		 &msg_txt("I see: $a[1]:$a[2]");		## prints their authorization in plain text
		 &output_txt( "235 AUTH OK");
		 $auth=$a[1];
		 $max_recipients = $sender->{max_recipients};
	
		} else {
		 &msg_txt("I see: $a[1]:$a[2]");		## prints their authorization in plain text
		 &msg_txt("I judge: 538 AUTHorization Failed \(dropping connection\)");
		 &output_txt("538 AUTH failed");
		 $quitnow=1;					## dump the connection on next WHILE
		 }
	   }  
	} elsif("\L$p[0]" eq 'CRAM-MD5') {
	 &output_txt("504 $p[0] unrecognized AUTH type");
    } else {
	 &output_txt("504 $p[0] unrecognized AUTH type");
    }

} #End of auth
#>---------------------------------------------------------
sub rset {
	# NOTE! Cannot undef $auth here because Courier does a RSET after successful auth Dec30,03
	# NOTE! Cannot undef $sender here because Courier does a RSET after successful auth Dec30,03
  undef @recipients; undef $bytes;
  &output_txt("250 OK $AUTH");
} #End of rset


#>---------------------------------------------------------
sub noop {
  &output_txt("250 OK");
} #End of noop


#>---------------------------------------------------------
sub help {
  &output_txt("214 read the frickin RFCs $auth");
} #End of help

#>---------------------------------------------------------
sub vrfy {
  &output_txt("550 You don't get to know this");
} #End of help

#>---------------------------------------------------------
sub mail {
	# As in MAIL FROM....
	# For inbound use, this would be the spammer...
	# For outbound we can make them AUTH first (no relaying allowed)
	# Note that RFC says this should come first in series of 3.
	#  AND that we should reset all buffers at this point (rfc 2821, sec 3.3)

	# Do regardless of failure status
	$sender_account = $this_user;
	$sender_domain = $this_domain;

	&msg_txt("in MAIL: adr=$adr / sender=$sender->{fqaddress}");


	# I notice there is no simple if auth=yes entry here... is that bad?
 	if(!defined($adr)){
	   &msg_txt("I do not see an address part! ($adr)");
	   &output_txt("550 No address found ($adr)");
	   return;
	   }
	

 	if($adr eq $sender->{fqaddress}){
	   ## Yippe! it is from the same address and they have already AUTHed
	   ## OK, they are cool!
	   &msg_txt("I judge: AUTH email account matches MAIL FROM account - full yes!");
	   &output_txt("250 OK $adr -3a-");
	   }
 	elsif(($sender_domain=~/\|$local_domains\|/io) && ($auth)){
	   ## Yippe! it is from (one of our domains) and they have already AUTHed
	   ## OK, they are cool!
	   $sender->{fqaddress}=$adr;
	   &msg_txt("I judge: AUTH email account matches domain list - half yes!");
	   &output_txt("250 OK $adr -3b-");
	   }
#	elsif(($sender_domain=~/\|$local_domains\|/io) && !($auth)){
#	   ## They have not AUTHed yet. :(
#	   # Check for a valid IP via list or reverse DNS?
#	   &msg_txt("I judge: AUTH=no but sending domain is valid)");
#	   &output_txt("550 Mail not accepted from $adr\[$remote_ip\] without valid login.");
#	   $quitnow=1;					## dump the connection on next WHILE
#	   }
	elsif(($sender_domain!~/\|$local_domains\|/io) && ($auth)){
	   ## They have AUTHed, but are spoofing a domain we do not own. :(
	   # Check for a valid IP via list or reverse DNS?
	   &msg_txt("I judge: AUTH=yes but sending domain is invalid. Report!!!)");
	   &output_txt("550 Mail not accepted: Are you spoofing your FROM?  No foreign domains even with a valid login.");
	   &bounce_localspoof($sender,$adr,$dated,$I_AM,$err);
	   $quitnow=1;					## dump the connection on next WHILE
	   }
#	elsif($relay){
#	   ## I accept this email because AUTH is set
#	   $sender->{fqaddress}=$adr;
#	   &msg_txt("I judge: is from a valid mail relay\)");
#	   &output_txt("250 OK $adr");
#	   }
	elsif(!ValidEmailAddr($adr)){
	   $sender->{fqaddress} = $adr;
	   &msg_txt("I judge: Mail not from our customer, and something else bad!");
	   &output_txt("550 \<$adr\> doesn't have a valid return path");
	   $quitnow=1;					## dump the connection on next WHILE

	   # check if on black hole list???
	   # REMd out by JF 24Feb02
	   #  if(!$relay && $remote_ip && &blackhole($remote_ip)) {
	   #  &msg_txt("blackholed");
	   #  $isSpam="blackhole";
	   #  }

	   }
	else{
		$sender->{fqaddress} = $adr;
		&msg_txt("I judge: Mail not from our customer, recipient better be!");
		&output_txt("250 OK $adr -3c-");
	   }



} #End of mail


#>---------------------------------------------------------
sub rcpt {
	my ($status,$err_out,$fqaddress,$base_address,$cust_id,$account_id,$recip_domain,$recip_account);
	# As in RCPT TO....
	# For inbound use, this would be our loyal client...
	# For outbound, if AUTH is set then fireaway!
	# P[0]: The next bit MUST be TO: and be case in-sensitive. ^=start of line

	## Right here check for local domain or not.  Decide if inbound or not.
	## Note that AUTH is only way to verify local to local!!!
	## Treat un-AUTH local to local as suspect or spoofed.
	## but since order of RCPT and MAIL is not set, check it also in DATA

	# if $adr contains a valid domain "@domain" (at end of the line, but also
	# preceded by 0 or more non-white space characters) then OK.
	# Also, put the leading non-white space characters into a buffer as $1

	$recip_account = $this_user;
	$recip_domain = $this_domain;

	# Is there a need for this?
	if (($auth) && ($recipient_count > $max_recipients)) {
			# There was an error, so issue 500 (failure) and pass the exact cause on
			&output_txt("550 Too many recipients <$recipient_count> for one email! Send it or not.");
			return;
		}

	if ($MRBLG_count > $$MRBLG) {
			# It seems the sender is guessing at addreses, so we stop them after x bad guesses
			&output_txt("550 Now you are just guessing... Mr. spammer?");
			$quitnow = 1;
			return;
		}

	if ($recip_domain=~/\|$local_domains\|/io) {
		# It is one of ours so do these tests
		&msg_txt("-XX> RCPT $adr is local so test it");
		($recip,$err_out) = lookup4_delivery($dbh,$recip_account,$recip_domain,$sender);

		&msg_txt("-2> stat=$recip->{status} CUID=$recip->{cust_id} ACCTID=$recip->{account_id} fq_addy=$recip->{fqaddress} base=$recip->{base_address} err=$err_out");

if($recip_account =~ m/emusic/i) {$err_out = 'spam';}
if($recip_account =~ m/jukokai/i) {$err_out = 'spammy';}

		if ($err_out) {
			# There was an error, so issue 5xx (failure) and pass the exact cause on
			&output_txt("$err_out");
			$MRBLG_counter += 1 ;		# Max Recipient Bad Local Gueses

			if($recip->{rules}=~/FIG\:([0-9a-zA-Z\.\-\_\@]+)/io) {
				# There is a FIGLET rule set. only one FIG: per account though bub
				bounce_figlet($sender,$adr,'FIGLET-1',$dbh);
				}

		} else {
			$recipient_count += 1;
			if ($recip->{rules}=~/FWD\:([0-9a-zA-Z\.\-\_\@]+)/io) {
		    	&msg_txt("We have a FORWARD");
				my $possible = $1;					##  i took out checking for valid Address here. JF Jan 09,2004
 				$possible=~/<([0-9a-zA-Z\.\-\_\:\@]+)(\@)([0-9a-zA-Z\.\-\_]+)>$/;	# Parse for valid email
				$recip->{'account_part'} = $1;			# take the account part (1st set of paren)
				$recip->{'domain_part'} = $3;			# take the domain part (3rd set of paren)
				$recip->{'fqaddress'} = $possible;
			}
			my $tmp = {} ;			# define tmp as an array
			$tmp->{'fqaddress'}		= $recip->{'fqaddress'};
			$tmp->{'base_address'}	= $recip->{'base_address'};
			$tmp->{'account_part'}	= $recip->{'account_part'};
			$tmp->{'domain_part'}	= $recip->{'domain_part'};
			$tmp->{'CUST_ID'}		= $recip->{'CUST_ID'};
			$tmp->{'account_id'}	= $recip->{'account_id'};
			$tmp->{'rules'}			= $recip->{'rules'};
			push(@recipients,$tmp);
			&output_txt("250 OK $fq_address");

			if($recip->{rules}=~/CC\:([0-9a-zA-Z\.\-\_\@]+)/io) {
				# There is a carbon copy rule set. only one CC: per account though bub
				$tmp = $1;		#Save the email address part
 				$tmp=~/<([0-9a-zA-Z\.\-\_\:\@]+)(\@)([0-9a-zA-Z\.\-\_]+)>$/;	# Parse for valid email
				$recip_account=$1;			# take the domain part (1st set of paren)
				$recip_domain=$3;			# take the domain part (3rd set of paren)

				($recip,$err_out) = lookup4_delivery($dbh,$recip_account,$recip_domain,$sender);


				if ($err_out) {
					# There was an error, so issue 5xx (failure) and pass the exact cause on
					# Forwards (ie: OK+FWD rule) is not handled here. So it wont be forwarded at all.  Design decision.
					&output_txt("$err_out");
					$MRBLG_counter += 1 ;		# Max Recipient Bad Local Gueses
				} else {
					my $tmp = {} ;			# define tmp as an array
					$tmp->{'fqaddress'}		= $recip->{'fqaddress'};
					$tmp->{'base_address'}	= $recip->{'base_address'};
					$tmp->{'account_part'}	= $recip->{'account_part'};
					$tmp->{'domain_part'}	= $recip->{'domain_part'};
					$tmp->{'CUST_ID'}		= $recip->{'CUST_ID'};
					$tmp->{'account_id'}	= $recip->{'account_id'};
					$tmp->{'rules'}			= $recip->{'rules'};
					$recipient_count += 1;
					push(@recipients,$tmp);
					&msg_txt("Found a carbon copy rule. Added ($recip->{fqaddress}) to recipient list");
				} #end if err_out CC:
			} #end if CC:
		} # end if err_out RCPT
		
	} elsif(($auth)&& (ValidEmailAddr($adr))) {
		&msg_txt("-A3>Found embedded email: <$1>");
		# OK, it isnt one of ours....
		# foreign address
		my $tmp = {} ;			# define tmp as an array
#		$tmp->{'fqaddress'}		= "$recip_account@$recip_domain";
		$tmp->{'fqaddress'}		= "$adr";
		$tmp->{'account_part'}	= $recip_account;
		$tmp->{'domain_part'}	= $recip_domain;
		$tmp->{'base_address'}	= "";
		$tmp->{'CUST_ID'}		= "";
		$tmp->{'account_id'}	= "";
		$tmp->{'rules'}			= "";
		$recipient_count += 1;
		push(@recipients,$tmp);
		&output_txt("250 OK $adr");
	} else {
		&output_txt("550 Relaying not allowed without proper AUTH first $auth");
	}

} #End of rcpt


#>---------------------------------------------------------
sub data {
	my ($sender,$remote_ip,$auth,$spool_dir,$recipient_count,@recipients) = @_ ;
	my ($too_big,$head_ok,$body_ok,$xmailer,$subject,$msg_body,$batterup,$start_time,$gmt_time,$tempname,$temppath,$SMN_menu_flag,$recip_count);
	
	# This step is where people normally filter content, we just want to verify a clean
	# and properly formatted headers+body

	# First we need to know is this inbound or outbound?  For now, assume inbound 24Feb02

	# Firstly - make sure we have enough data to seek on. Is $auth? or $valid_recipient?

    if(!defined($sender->{fqaddress})) {
	&output_txt("503 Yeah, right.  Tell me who you are first!");
	$quitnow = 1;
	return;
    }

	&msg_txt("-16>recip=$recipient_count/@recipients");		#shouldn't be broken

    if($recipient_count = 0) {
		## if(!defined(@{$recipients})) {
		&output_txt("503 You want me to read your mind?  Tell me who to send it to!");
		$quitnow = 1;
		return;
    }

	$msg_body = "";		# Empty the email variable.
	$msg_size = 0;		# Empty the email size variable.

	my $gmt_time=gmtime;
	my $start_time=time;
	my $file_time=localtime;

	my $tempname="$start_time.P$$.$me";		## $$ is the PID, http://cr.yp.to/proto/maildir.html
	my $temppath="$tmp/$tempname";

	# Since data we add to the headers can change based upon text in the HTML part,
	# we must actually change the headers last.
	$header = "Received: from ($remote_hostname\[$remote_ip\])(HELO $helo)\r\n\tby $me(ESMTP id $$) as $sender->{fqaddress} \r\n\tfor $to $gmt_time (GMT0)\r\n";
   &output_txt("354 Start mail input; end with <CRLF>.<CRLF>");

	# At this point the user is sending the headers
	while(<STDIN>) {
		 &input_txt("Head: $_");
		if((/^\r\n$|^\n$/)) {	# when we hit a blank line the headers are supposed to be over.
								# also we could look for the lack of ": " as all headers seem to need to conform
		  $header .= $_;			 # Since last, add this line to the bottom of the msg body here
		  $msg_length += length($_); # and increment msg size, duh!
   		  $head_ok = 1;				 # set exit condition as OK
   	   	  last;
		  ## Add a FROM header if it doesn't already exist
		  ## \b(word boundary) +\S non whitespace multiple char /i case insens
		  #$header .=  "From: $sender->{fqaddress}\n" unless $header=~/\bfrom: +\S/i ;
		  }

		 s/^\.\./\./;					# RFC 821 compliance, change .. to . if starts a line
	
		 # check if blank subject, $2 can also be exported as the subject. :)
		 if ($_=~/^subject:(\s*)(.+)/io) {
		 	$subject = $2;
			$subject =~ s/\r//g;		## if there is a carriage return, delete it
			if ($subject eq "") {
				$subject = "<Sender left the subject line empty>";
				&msg_txt("Corrected empty subject line: <$_>");
				$_="Subject: <Sender left the subject line empty>\r\n";
				}
		 	}
	
		 # Check if the Mailer identifies itself, is collect the data
		 if ($_=~/^(X[a-zA-Z0-9\-\_\ ]+):(\s*)(.+)/io) {
		 	# $1 X-Header, $2 is zero or more spaces, $3 is everything after that upto the end
			my $tmp = {} ;			# define tmp as an array ?need this?
			&msg_txt("  Found email header!: $1/$3");
			$tmp->{'header'} = $1;
			$tmp->{'value'} = $3;
			push(@xheaders,$tmp);
			if ($1=~/X-mailer/io) {
				$xmailer = $tmp->{value};			# set the X-Mailer for later!
				}
		 	}

		 # Content-Type marks the end of the orthodox headers \;.+
		 if ($_=~/^Content-Type:(\s*)(.+)$/io) {
		 	# $1 is zero or more spaces, $2 is everything after that upto the end
			# multipart/alternative;
			# text/plain;
			# text/html;
			# last;					# this should end the headers also
		 	} # end of Content-type

		# Some doooofuses mix CRLF then LF lines into the headers. Damn them
		if ($_!~/\r\n$/io) {
			#We have established the line doesn't end correctly. Now test for LF only
			if($_=~/\n$/io) {
				&msg_txt("-LR> fixing line end by replacing LF with CRLF");
				$_=~s/\n/\r\n/io;
			}else{
				&msg_txt("-LS> fixing line end by adding a CRLF");
				$_ .= "\r\n";
			}
		} #end if line ends right-like

		 $header .= $_;					# add this line to the bottom of the msg body
		 $msg_length += length($_);
	} # End while headers


	## What kind of headers were used? add to SQL db
	# Cycle through them
	if (!$xmailer) {
		# X-Mailer header strangely not defined by this stinky client
		$xmailer = "NA";
		#&msg_txt("  Anually adding X-Mailer header!: $xmailer");
		$tmp->{'header'} = "X-Mailer";
		$tmp->{'value'} = "NA";
		push(@xheaders,$tmp);
	}
	foreach $x (@xheaders) {
		if ($$x{header}=~/x-mailer/io) {
			&log_xheaders($xmailer,"NA","NA",$dbh);
		}elsif($$x{header}=~/x-stinky/io) {
			#some action, or just skip logging it...
		}else{
			#Log everything else
			&log_xheaders($xmailer,$x->{header},$x->{value},$dbh);
		} end if
		&msg_txt("Processed xheader: $x->{header}: $x->{value}");
	}#end foreach

	# check if Subject exists yet, if not add it before content-type line
	#if ($subject eq "") {
	#	&msg_txt("subject3: adding a new header...");
	#	$header .="Subject\: <Sender left the subject line empty>\r\n";
	#	} #End if subject

	#---------- here beginnith the body text
	$SMN_menu_flag = 0;

	while(<STDIN>) {
		
		alarm $timeout;	
		if(/^\.\r\n$/) {			# when we hit a line soley a period followed by a CR/LF
	    	$body_ok = 1;				# the body is supposed to be over.
	    	last;
		}

		if ($auth) {
			# Time to check for outbound stuff!
			# If it is outbound, it should already be in HTML (because we ALWAYS deliver HTML, right?)

			if ($_=~/^Content-Type\: text\/html\;(.+)$/io) {
	 			# $1 is everything after that upto the end
				&msg_txt("-40>inHTML flag set! $_");
				$inHTML_part = 1;
			} # end of Content-type HTML

			if ($SMN_menu_flag) {
				# OK inside the spammenot tags.  find the end 
				if($SMN_menu_flag==1) {
					# if the line is broken then
					# We are still expecting an email address about here....
					if ($_=~/^[\ ]*([0-9a-zA-Z\-\_\.\@\#]+)/io) {
						# We found and email address? Verify
						if (ValidEmailAddr($1)) {
							&msg_txt("-44>Found embedded email: <$1>");
							$sender->{fqaddress} = $1;
							$SMN_menu_flag = 2;		# We have the new FROM address 
						}
					} else {
						&msg_txt("-45> Badd juju, no email found in: <$_>");
					} #end if contains email
				} #end if SMN_menu_flag = 1


				if($_=~/[\s\s]*<\/SPAMMENOT>(\s\s+)$/) {
					&msg_txt("-46>SMN menu close found in outbound mail $_/$1");
	 				# $1 = anything after the tag closed
					$SMN_menu_flag = 0;
					$_ = $1;
				} else {
					&msg_txt("-42>discarding text $_");
					# This is a trash line inside the SMN menu
					# How do we nullify it and re loop?
					next ;
				} # end of trailing tag
			} # end of SMN flag 

			# CR/LF +SMN_flag means remove the added HTML menu!
			# &msg_txt("-401>SMN menu <$SMN_menu_flag>$_");

			if($_=~/([\w\ \:\;\#\%\=\<\>\"\'\-]*)<SPAMMENOT(\ [0-9a-zA-Z\-\_\@\>\#]*|>|[\ \r\n]*)/) {
				$SMN_menu_flag = 1;			# we have found the start of the spammenot menu, but MAYBE not a valid email
				&msg_txt("-41>SMN menu found in outbound mail $_/$2");
	 			# $1 = anything before the tag, should be a <BODY> tag, but may NOT be!
	 			# $2 = could be the original plussed recipient, parse it!
				$_ = $1;
				my $trailed = $2;
				if ($trailed=~/^>/) {
						$SMN_menu_flag = 2;		# There wasn't a new FROM address
				}elsif ($trailed=~/^ ([0-9a-zA-Z\-\_\@]+)/) {
					if (ValidEmailAddr($1)) {
						&msg_txt("-43>Found embedded email: <$1>");
						$sender->{fqaddress} = $1;
						$SMN_menu_flag = 2;		# We have the new FROM address 
					}
				} #end if trailed
			} #end if <spammenot

			if ($_=~/^\[from:(\s*)([0-9a-zA-Z\.\-\_\:\@\#]+)/io) {
				# looking for [from:, will most likely be in the text part
	 			# $1 is what they want to be known as!
				&msg_txt("-48>SMN new reply to found! $_");
				$SMN_reply_flag = 1;
				my $possible_email = $2;
				if (ValidEmailAddr($possible_email)) {
					$err_out = "bleah";			# Set a default to NOT accept the new address unitl proven
		 			if ($possible_email =~/([0-9a-zA-Z\.\-\_]+)(\@)([0-9a-zA-Z\.\-\_]+)/) { #extract user/@/domain
						my $account=$1;			# take the user part (1st set of paren) as is
						my $domain=$3;			# take the domain part (3rd set of paren)
						my ($us,$err_out) = lookup4_delivery($dbh,$account,$domain,$sender);
					
						if (($err_out) && (($us->{status} eq "PRIVATE"))){
							# address is possibly valid, ignore the err_out flag
							&msg_txt(" 1 Changing to new FROM/REPLY-TO! old=$sender->{fqaddress} new=$possible_email");
							$sender->{fqaddress} = $possible_email;
						} elsif ($err_out){
							&msg_txt(" NOT Changing to new FROM/REPLY-TO! $err_out");
							# There was an error, so DONT change the address
							# probably should notify the user too?
						} else {
							&msg_txt(" 2 Changing to new FROM/REPLY-TO! old=$sender->{fqaddress} new=$possible_email");
							$sender->{fqaddress} = $possible_email;
						} #End if ok to change From address
						
					next;	#Trash this line, do not keep in email
                    } #end of if possible_email contains 
				} # End if ValidEmail	
			} # end of if {from: xxxxx]
	
	} #End if(auth) ie: if msg_direction=out


	 s/^\.\./\./;					# RFC 821 compliance, change .. to . if starts a line
	 $msg_body .= $_;				# add this line to the bottom of the msg body
	 $msg_length += length($_);


     # Hey, we can set a minimum file size to actually write to a file, otherwise hold in a variable in memory
	if ($msg_length >12000) {
		# msg is getting kind of large, so dump the variable into a file
		if(!defined($too_big)){
			$too_big = 1;
	 		unless(open(TMP,">$temppath")) {
      		  &output_txt("554 Server file creation error -- try again later\r\n221 sorry");
      		  return;
      		  }
			print TMP "$header\r\n";		# dump existing content into file
			print TMP "$msg_body\r\n";		# dump existing content into file
			&msg_txt("MSG too large to store in memory, going dark until it's over...");
      	 } else {
      	 	## OK, so the file was already made, just dump the new lines in!
			print TMP "$_";
      	 }
	}else{
		&input_txt("Body: $_");
	} #end if msg_length too big


	} # End while client!

#---------- here endeth the body text



    if(!($head_ok)||!($body_ok)) {
		&msg_txt("headers=$head_ok  body=$body_ok");
	    # We never saw the end string and the socket dropped.
     	&output_txt("550 Fine...who needs you anyway!");
	 	unlink($temppath);
	 	return 1;
     	}

	$bytes=tell(TMP);			# how big is the msg?
	close TMP;					# make it so!

	# For each recipient in @recipients, deliver locally or queue or outbound
	# What about filling up the disk, ie: quotas?  Maybe deliver this last one and change status for next incoming

#	my @recip_list = @recipients ;			## Copy the variable so we can decrement the data
#	while (@recip_list) {
	
	# Cycle through the recipient list, put each new one into batterup
	foreach $batterup (@recipients) {

		my ($recip_account,$recip_domain);
		$recip_count += 1;				## In case of multiple outbound, make filename unique

		$to = $$batterup{'fqaddress'};		## Give me the next batter! (note double $$, by reference)

		$base_address = $$batterup{'base_address'};		## What home dir to use?

		$recip_account = $$batterup{'account_part'};	## splitty again? nah!
		$recip_domain  = $$batterup{'domain_part'};

		#if ($to =~/([0-9a-zA-Z\.\-\_\:\@]+)(\@)([0-9a-zA-Z\.\-\_]+)$/) { #extract user/@/domain
		#	$recip_account=$1;			# take the user part (1st set of paren) as is
		#	$recip_domain=$3;			# take the domain part (3rd set of paren)
		#}

		&msg_txt("-17> ($too_big)$$batterup{base_address}/$to/$$batterup{recip_account}/$$batterup{recip_domain}/$tempname");


		## process the email into the proper directory
		if($too_big) {
			my $spoolto;
			if ($recip_domain=~/\|$local_domains\|/io) {
				## mail is in a file and is inbound, so parse and mv
				#$new_filename = MIME_pummel_file($to,$sender,$tmp,$tempname);

				my $deliver_dir="$base_maildir/$recip_domain/$base_address/new";
					unless (-d $deliver_dir	and	opendir	DIR, $deliver_dir ){
						&msg_txt("-N1> MailDir failure opening: $deliver_dir");
			 			# go make the stupid directories. reversed order to save code
						if(make_directories('new',$base_address,$recip_domain,$base_maildir)) {
							unless (-d $deliver_dir	and	opendir	DIR, $deliver_dir ){
								&msg_txt("-N2> MailDir failure creating: $deliver_dir");
		    		  			&output_txt("554 Server file creation error 12 -- try again later\r\n221 sorry");
							} #End second unless open
						} #End if make Dir
      			  	} #End first unless open
				$spoolto="$deliver_dir/$recip_count.$tempname";

			} elsif($recip_domain!~/\|$local_domains\|/io) {
				## mail is in a file and is outbound, so parse and send
				#$new_filename = MIME_pummel_file($to,$sender,$tmp,$tempname);

				$spoolto="$spool_dir/$recip_count.$tempname";

				# Now wrote out the patch to make a .extra file containing the X-Orig header
				if (open(TMP,">$spool_dir/\+$recip_count.$tempname.extra")) {
					my $header = "X-Original-To: <$to>\r\n";	# add custom send-to for our smtp_cron!
					print TMP "$header";
					close TMP;
					&msg_txt("-J1> written new $spool_dir/\+$recip_count.$tempname.extra file");
				}else{
					&msg_txt("-J1> FAILED! opening $spool_dir/\+$recip_count.$tempname.extra");
				}				
			}


			move ($temppath, $spoolto);
			&msg_txt("-N3> email written to $spoolto");
		} # end too big

		if(!$too_big) {
			&msg_txt("-18> email in memory: $to/$sender->{fqaddress}/$base_address/\n$header");

			my $new_email = MIME_pummel_memory($to,$sender,$header,$msg_body);
			&msg_txt("-19> Complete email returned from MIME_pummel:\n$new_email");

			if ($recip_domain=~/\|$local_domains\|/io) {
				&msg_txt(" <$recip_domain> is local, write it out");
				## mail is in memory and is inbound
				my $deliver_dir="$base_maildir/$recip_domain/$base_address/new/$recip_count.$tempname";
			 		unless(open(TMP,">$deliver_dir")) {
			 			# go make the satupid directories. reversed order to save code
						if(make_directories('new',$base_address,$recip_domain,$base_maildir)) {
					 		unless(open(TMP,">$deliver_dir")) {
		      		  			&msg_txt("failed to $deliver_dir");
		    		  			&output_txt("554 Server file creation error 12 -- try again later\r\n221 sorry");
							} #End second unless open
						} #End if make Dir

      			  	} #End first unless open
      		  	if (print TMP "$new_email") {		# dump existing content into file
      		  		&msg_txt("email written to $deliver_dir");
				}else{
      		  		&msg_txt("failed to $deliver_dir");
    		  		&output_txt("554 Server file creation error 13 -- try again later\r\n221 sorry");
      		  	}
				close TMP;					# make it so!

			} else {
				## file is outgoing but it is still in memory
				&msg_txt("-31> ($recip_domain) is NOT a local domain, spool it out");
				my $spoolto="$spool_dir/$recip_count.$tempname";
		 		if (open(TMP,">$spoolto")) {
      		  		if (print TMP "$new_email") {
      		  			&msg_txt("email written to $spoolto");
      		  		}else{
      		  			&msg_txt("email write failed to $spoolto !!! ");
      		  		} #end of file write
				}else{
    	  			  &msg_txt("HEY!!!! cannot create the spool file: $spoolto\nInfo: to=$to from=$sender->{fqaddress}");
      			} #end of file open
				close TMP;					# make it so!
			}
		} #end of if !too big


		## Add or increment appropriate SQL tables, including quota update?


	} # End of while recip_list



		
		

 	unlink($temppath);			## All recipients are served, time to let the past go

	## Save this until the very end, becuase if the other end drops the connection the script will die!
	&output_txt("250 OK received $bytes/$msg_length bytes");					## Email was accepted!

	return ;
} #End of data





#########################################################################
#SUBROUTINES
#########################################################################

sub lookup4auth{
	my ($address,$dbh) = @_;
	my $tmp = {} ;			# define tmp as an array

	##http://www.perl.com/pub/a/1999/10/DBI.html
	my $sth = $dbh->prepare('SELECT *  
				 FROM accounts 
				 where FQ_ADDRESS=?') 
				 or die &msg_txt("Couldn't prepare SQL err: $dbh->errstr");

	$sth->execute($address) or die "Couldn't execute SQL err: " . $dbh->errstr;

	if ($sth->rows == 0) {
    	&msg_txt("No accounts matched `$address'");
	}else{
		my $ref = $sth->fetchrow_hashref();
		
		$tmp->{fqaddress}		= $address;
		$tmp->{pw}				= $ref->{'PASSW'};
		$tmp->{status}			= $ref->{'STATUS'};
		$tmp->{account_id}		= $ref->{'ACCOUNT_ID'};
		$tmp->{cust_id}			= $ref->{'CUST_ID'};
		$tmp->{rules}			= $ref->{'RULES'};
		$tmp->{max_recipients}	= $ref->{'MAX_RECIP'};
		&msg_txt("Found a row: addy=$tmp->{fqaddress} pw=$tmp->{pw} stat=$tmp->{status} max_recip=$tmp->{max_recipients} rules=$tmp->{rules}");	
	} #end of if records exist

	$sth->finish();

   if ($tmp->{status} ne 'OK'){$tmp->{pw}="rejected";}
   
   return $tmp;

} # end of lookup4auth

#>----------------------------------------------------------------------------
sub lookup4_delivery{
   my ($dbh,$recip_account,$recip_domain,$sender)= @_;
   my ($trusted,$status,$accountID,$userID,$fqaddress,$err_out,$tmp);
   

	$fqaddress = "$recip_account\@$recip_domain";

	# Was -34>
	&msg_txt(" LFD-1>Validating email: $fqaddress");

	if (!ValidEmailAddr($fqaddress)) {
			$err_out="550 <$fqaddress> is malformed";
			} # End of if inbound

	# is it even one we are responsible for?
	if(!($recip_domain=~/\|$local_domains\|/io)) {
			$err_out="550 <$fqaddress> see ya";
			} # End of if inbound

	if ($err_out) {
		return $tmp,$err_out;
		}  # end if


   ## Yippe! it is targeted to (one of our domains)
   ## Time for MySQL lookup of target user

	#First we see if they have a base account to load up the usual details
	my @t=split(/\./,$recip_account);			## split up the target user into pieces at each "."
	&msg_txt(" LFD-2> I see:$this_user=$t[0]+$t[1]+$t[2]");

	# First test/search on first most significant (winnie part of winnie.pooh.extra@)
	my $search_4=$t[0];			## make it x
	&msg_txt(" LFD-3> Searching for:$search_4 + $recip_domain");

	# Now retrieve data from the table.
	$sth = $dbh->prepare("SELECT *
				 		FROM accounts
				 		WHERE ADDRESS=?
				 		 and DOMAIN=?");

	$sth->execute($search_4,$recip_domain);
	
	my $counter = ($sth->rows);
	&msg_txt(" LFD-4> Found $counter records matching $search_4\+$recip_domain");

	if ($counter) {
		my $ref = $sth->fetchrow_hashref();
			$tmp->{fqaddress}=$ref->{'FQ_ADDRESS'};
			$tmp->{base_address}=$ref->{'ADDRESS'};
			$tmp->{account_part}=$ref->{'ADDRESS'};
			$tmp->{domain_part}=$ref->{'DOMAIN'};	
			$tmp->{account_id}=$ref->{'ACCOUNT_ID'};
			$tmp->{cust_id}=$ref->{'CUST_ID'};
			$tmp->{debug_flag}=$ref->{'DEBUG'};
			$tmp->{rules}=$ref->{'RULES'};
			$tmp->{status}=$ref->{'STATUS'};
			$tmp->{plussed} = "$t[1]$t[2]";

     } elsif(!defined($t[1])){
			# There wasn't a second part to lookup!
	     	# So not a valid recipient. Soooooory. NOt.
			$err_out="550 <$fqaddress> Not a valid address - see ya";
     } else {
		
		# Time to look again, but for a double (winnie.pooh part of winnie.pooh.extra@)
		my $search_4=$t[0].'.'.$t[1];
		&msg_txt(" LFD-5> Searching for:$search_4 + $recip_domain");

		# Now retrieve data from the table.
		$sth = $dbh->prepare("SELECT *
					 		FROM accounts
					 		WHERE ADDRESS=?
					 		 and DOMAIN=?");
		$sth->execute($search_4,$recip_domain);

		my $counter = ($sth->rows);
		&msg_txt(" LFD-6> Found $counter records matching $search_4\+$recip_domain");
		
		if ($counter) {
	    	&msg_txt("We have a winner!");
			my $ref = $sth->fetchrow_hashref();
			$tmp->{fqaddress}=$ref->{'FQ_ADDRESS'};
			$tmp->{base_address}=$ref->{'ADDRESS'};
			$tmp->{account_part}=$ref->{'ADDRESS'};
			$tmp->{domain_part}=$ref->{'DOMAIN'};	
			$tmp->{account_id}=$ref->{'ACCOUNT_ID'};
			$tmp->{cust_id}=$ref->{'CUST_ID'};
			$tmp->{debug_flag}=$ref->{'DEBUG'};
			$tmp->{rules}=$ref->{'RULES'};
			$tmp->{status}=$ref->{'STATUS'};
			$tmp->{plussed} = $t[2];
	     } else {
	     	# Not a valid recipient. Soooooory. NOt.
			$err_out="550 <$fqaddress> Not a valid address - see ya";
			} # End of if counter(x.y)
		} # End of if counter(x)


	if ($err_out) {
		return $tmp,$err_out;
		}

	# OK! Good news they have an account, lets check for problems....
	&msg_txt(" LFD-7> stat=$tmp->{status} dbg=$tmp->{debug_flag} rules=$tmp->{rules} plussed=$tmp->{plussed}");

	if ($tmp->{status} eq "OK") {
		# Do nothing, it is OK
	}elsif ($tmp->{status} eq "ON HOLD") {
		$err_out="450 We must temporarily reject ($tmp->{fqaddress}). Sorry!";
	}else{
		$err_out="550 rejecting ($tmp->{fqaddress}). ";
		# increment the blocked counter for the ACCOUNT (base)?
		} # End of if STATUS

	if ($err_out) {
		return $tmp,$err_out;
		}


	# base rules?  Like what exactly.... whitelisting? Figlet?
	#if($rules=~/'whitelist_base'/io) {

	# See if there is a match in TPOL, or reject
	my ($tmp2) = lookup_TPoL($tmp,$sender,$dbh);
		
	if ($tmp2->{trusted} eq "REJECT") {
		# this means the user has disabled this address permanently
		$err_out="550 ($tmp->{fqaddress}) is permanently closed ";
		$tmp->{status} = $trusted;
		#increment_TPOL_counter($fqaddress,$sender->{fqaddress},$dbh));
		
	} elsif ($tmp2->{trusted} eq "PRIVATE") {
		# this means the user rejects emails until they are on the whitelist
		# if private the owner must add the user manually or send them an email...
		# if +figlet the system will generate another email to the sender with the figlet 
		# in any case the recipient is NOT added to the @recipient{} hash. 
		# So the mail is not delivered to them.  If Figlet they have to resend, for now.
		$err_out="550 ($tmp->{fqaddress}) is protected by a whitelist service and you are not on the list.";
		$tmp->{status} = $trusted;

			# I also had a notion to set the sender/recip pair trusted as a number instead of OK.
			# So it is listed as private+figlet, or 1, or REJECT.  simple?
			# Go look that up.
		}

	# trusted must be must be 'YES', so thumbs up this email address.

	&msg_txt(" LFD-8> stat=$status UID=$cust_id ACCTID=$account_id fqaddy=$fqaddress rules=$rules");

	# Search_4 should still contain the base accout name (ie: 'winnie' of winnie.extra.stuff@)
	return $tmp,$err_out;
}




#>----------------------------------------------------------------------------
sub lookup_TPoL {
	my ($us,$sender,$dbh) = @_;
	my ($trusted,$rules,$sth,$rec,$domain)

	## Now we need to check for extenuating cirumstances in the TPOL db
	&msg_txt("Searching TPOL for combo: $us->{fqaddress} + $sender->{fqaddress}");

	# Now retrieve data from the table.
	$sth = $dbh->prepare("SELECT *
				 		FROM TPoL
				 		WHERE OUR_ADDRESS=?
				 		 and THEIR_ADDRESS=?");
	$sth->execute($us->{fqaddress},$sender->{fqaddress});
	
	if (($sth->rows) >= 1) {
    	&msg_txt("We have a winner!");
		my $rec=$sth->fetchrow_hashref();
			$trusted = $rec->{'TRUSTED'};
			if ($rec->{'TRUSTED'}){$us->{trusted} = $rec->{'TRUSTED'};}
			if ($rec->{'RULE'}){$us->{rules} = $rec->{'RULE'};}
			if ($rec->{'CD_COUNT'}){$us->{cr_count} = $rec->{'CR_COUNT'};}
	    }
	$sth->finish();
    
	if ($us->{cr_count} >= 1) {
		# This is a figlet responce, meaning they replied and we will let x through.
		# x is a number from 0-10, should decrement later. Spoof as OK, but decrement the counter
		# when it hits zero the figlets will resume.

		$us->{trusted} = "OK";
		$us->{cr_count} = 0 ;

		# go update the record and decrement it.  If 1, it should auto 'reset' to zero.
		CR_counter_decrement($us,$sender,$dbh);
		}


    if (!($trusted)) {
		# didn't find a record for this guy yet, is there a REJECT entry?

		&msg_txt("Searching TPOL for combo: $us->{fqaddress} + ALL}");
	
		# Now retrieve data from the table.
		$sth = $dbh->prepare("SELECT *
					 		FROM TPoL
					 		WHERE OUR_ADDRESS=?
					 		 and THEIR_ADDRESS=?");
		$sth->execute($us->{fqaddress},'ALL');
		
		if (($sth->rows) >= 1) {
			my $rec=$sth->fetchrow_hashref();
			if ($rec->{'TRUSTED'}){$us->{trusted} = $rec->{'TRUSTED'};}
			if ($rec->{'RULE'}){$us->{rules} = $rec->{'RULE'};}
	    	}
		$sth->finish();
		} # End if DEFAULT record



#	    	&msg_txt("We have a FORWARD");
#			my $rec=$sth->fetchrow_hashref();
#				$trusted=$rec->{'TRUSTED'};
#				$rules=$rec->{'RULE'};				##### Hey! put the email to forward to in RULES
#				$rules=~/FWD\:([0-9a-zA-Z\.\-\_\@]+)/io;
#				my $possible = $1;
#				if (ValidEmailAddr($possible)) {
#					$us = $possible;
#				} else {
#					# since we don't have a valid FWD address, we have to reject. :(
#					# send an email to the user that their rule is screwed
#					$trusted = "REJECT";
#				}
#

	return $trusted,$us,$rules;

} #end lookup_TPoL


#>----------------------------------------------------------------------------
sub incrementTPOL {
	my ($to,$sender,$dbh) = @_;
	my ($sth,$domain);
	
	
 	$to=~/<([0-9a-zA-Z\.\-\_\:\@\#]+)(\@)([0-9a-zA-Z\.\-\_]+)>$/;	# Parse for valid email
	$domain=$3;			# take the domain part (3rd set of paren)
	# Now update this pair counter for SENT...
	if($domain=~/\|$local_domains\|/io) {
		$sth = $dbh->prepare("UPDATE TPoL 
					SET COUNT_RCV=COUNT_RCV+1 
					WHERE OUR_ADDRESS=?
					 and THEIR_ADDRESS=?");
		$sth->execute($to,$sender->{fqaddress});
		$sth->finish();
		} # End if


	# Check to see if we need to update the sent to counter 
 	$sender->{fqaddress}=~/<([0-9a-zA-Z\.\-\_\:\@\#]+)(\@)([0-9a-zA-Z\.\-\_]+)>$/;	# Parse for valid email
	$domain=$3;			# take the domain part (3rd set of paren)
	if($domain=~/\|$local_domains\|/io) {
		# Now update this pair counter for SENT...
		$sth = $dbh->prepare("UPDATE TPoL 
					SET COUNT_SENT=COUNT_SENT+1 
					WHERE OUR_ADDRESS=?
					 and THEIR_ADDRESS=?");
		$sth->execute($sender->{fqaddress},$to);
		$sth->finish();
		} # End if

} #end increment_TPoL



#>----------------------------------------------------------------------------
sub MIME_pummel_memory {
	my ($to,$sender,$headers,$body) = @_;
	my $whole_msg;

	&msg_txt("-20000> IT came into pummel like this\n\n$headers");

	## This routine goes through an email in memory and ADDS the spammenot menu, etc.
	##if contains 'Content-Transfer-Encoding: base64' tell somebody!

	# 1) go through headers and change the From:, Reply-to:, and Return-path entries
	# 2) Make sure the email has HTML part if is inbound to us
	#	 Optionally strip the plain text out?
	#	 Then add our menu to that

	# is this email FROM one of us?
	if ($sender->{fqaddress}=~/\|$local_domains\|/io) {
		&msg_txt("-20> changing FROM headers: $sender->{fqaddress}");
		# What are the odds this needs to be changed?
		#$headers=~s/(.*\nfrom\:[0-9a-zA-Z\.\-\_\:\@\"\ \!]* <).+(>.*)/$1$sender->{fqaddress}$2/ios;	# change the from: address only (not the name in quotes)
		$headers=~s/(.*\nfrom\:[\ \"\w]*<)[0-9a-zA-Z\.\-\_\@\#]+(>.*)/$1$sender->{fqaddress}$2/ios;
			#&msg_txt("\n\nChanging the FROM in headers:\n1=$1\n\n2=$2");
		$headers=~s/(.*\nreturn-path\:[\ \"\w]*<)[0-9a-zA-Z\.\-\_\@\#]+(>.*)/$1$sender->{fqaddress}$2/ios;
		$headers=~s/(.*\nreply-to\:[\ \"\w]*<)[0-9a-zA-Z\.\-\_\@\#]+(>.*)/$1$sender->{fqaddress}$2/ios;

		$headers = "X-Original-To: <$to>\r\n$headers";	# add custom send-to for our smtp_cron!

		# removed Mar02,04 by JF for James
		# $SMN_footer = build_SMNfoot();
		# $body = insert_SMNfoot($SMN_footer,$body);
	}
	&msg_txt("-20002> DID IT change YET\?\n\n$headers");

	# Have to combine them for this next step anyway...
	$whole_msg = "$headers$body";

	# is this email TO one of us?
	if ($to=~/\|$local_domains\|/io) {
		&msg_txt("-21> Inbound! Adding inline SMN menu");
		# Does this email have an HTML part?
		$whole_msg = containsHTML($whole_msg); 

		#$SMN_menu = build_SMNmenu($to,$sender,$whole_msg);
		#$whole_msg = insert_SMNmenu($to,$SMN_menu,$whole_msg);
	}

	return $whole_msg;
	
} #end MIME_pummel

#>----------------------------------------------------------------------------
sub MIME_pummel_file {
	my ($to,$sender,$tmp,$tempname) = @_;
	my $new_filename;
	my $temppath="$tmp/$tempname";

	## This routine goes through an email on disk and ADDS the spammenot menu, etc.


	#Open the file snd spool it into another file




	return $new_filename;

} #end MIME_pummel




#>----------------------------------------------------------------------------
sub containsHTML{
	my ($whole_msg) = @_;

		if ($whole_msg!~/Content-Type\: text\/html\;/ios) {
			# Drat, it doesn't contain HTML yet.
			&msg_txt("-22a> MSG doesn't seem to contain HTML!");
			# magic happens	
		}else{
			&msg_txt("-22a> MSG contains an HTML content section");
		}	

	return $whole_msg;

} #end of contains HTML


#>----------------------------------------------------------------------------
sub build_SMNmenu{
	my ($to,$sender,$body) = @_;
	my $SMN_menu,$EQ_,$tsize;
	# This is where we will build our special PHP links
	#	if ($body=~/\=3D/) {
	#		# This message is using the stupid =3D notation from MS
	#		$EQ_ = "\=3D";
	#	}else{
	#		$EQ_ = "\=";
	#	} #end if body
	#	&msg_txt("   SMNmenu using <$EQ_> as the equal sign");

	$EQ_ = "\=";
	$tsize="SIZE$EQ_\"-1\"";
	$SMN_menu = "\r\n<SPAMMENOT $to>\r\n<table border$EQ_\"0\" width$EQ_\"100\%\" bgcolor$EQ_\"\#eeeeee\">\r\n<tr>\r\n";
	$SMN_menu .= " <td width$EQ_\"41\" rowspan$EQ_\"2\"><img border$EQ_\"0\" src$EQ_\"http://spammenot.com/art/fish_ittybitty.gif\" width$EQ_\"39\" height$EQ_\"39\"><\/td>\r\n";
#	$SMN_menu .= " <td width\=#d\"60%\"><FONT $tsize><B>To\:</B> $to<br><B>From\:</B> $sender->{fqaddress}<\/td>\r\n";
	$SMN_menu .= " <td><FONT $tsize><B>To\:</B><\/FONT><\/td>\r\n <td width\=#d\"60%\"><FONT $tsize>$to<\/FONT><\/td>\r\n";
	$SMN_menu .= " <td rowspan$EQ_\"2\">Reply to Trust this sender<\/td>\r\n";
	$SMN_menu .= " <td rowspan$EQ_\"2\">Block this email<\/td>\r\n";
	$SMN_menu .= "<\/tr><tr>";
	$SMN_menu .= " <td><FONT $tsize><B>From\:</B><\/FONT><\/td>\r\n <td width$EQ_\"60%\"><FONT $tsize>$sender->{fqaddress}<\/FONT><\/td>\r\n";
	$SMN_menu .= "<\/tr><\/table>\r\n</SPAMMENOT>\r\n";

	# &msg_txt("SMN menu: $SMN_menu");

	return $SMN_menu;
}
#>----------------------------------------------------------------------------
sub build_SMNfoot{
	my $SMN_foot;
	# This is where we will read in the latest/random footer

	$SMN_foot = "\r\n<br><br><HR>lose spam now, ask me how!<br>\r\n";
	$SMN_foot .= "<a href=\"http://www.spammenot.com\">www.spammenot.com</a><br>\r\n";

	# &msg_txt("SMN footer: $SMN_foot");

	return $SMN_foot;
}
#>----------------------------------------------------------------------------
sub contains_TEXT{
	my ($whole_msg) = @_;

	# Content-Type TEXT is my que to insert the SMN information line(s)
	# but only if the msg is inbound!
	if ($whole_msg=~/Content-Type\: text\/plain\;/ios) {
		# Cool, it has a plain text part, lets find it and exploit it
		
		# magic happens	
	} elsif ($whole_msg!~/Content-Type\:/ios) {
		# Cool, it has a plain text part, lets find it and exploit it
		
		# magic happens	
	}
	return $whole_msg;
} # End of contains_TEXT



#>----------------------------------------------------------------------------
sub insert_SMNmenu{
	my ($to,$SMN_menu,$whole_msg) = @_;
	#&msg_txt("Insert_SMNmenu, looking for:-------------\n\n\n$whole_msg<EOF>\n\nInserting:----------$SMN_menu\n\n");

	# Content-Type HTML is my que to insert the SMN menu
	# but only if the msg is inbound!
	if ($whole_msg=~s/(.+)(<body[0-9a-zA-Z \-\:\=\#\"]*>)(.+)/$1$2$SMN_menu$3/ios) {
			&msg_txt("-21a> SMN menu inserted after $2");
		}

	return $whole_msg;
} # End of add SMN menu

#>----------------------------------------------------------------------------
sub insert_SMNfoot{
	my ($SMN_foot,$whole_msg) = @_;
	#&msg_txt("Insert_SMNfoot, looking for:-------------\n\n\n$whole_msg<EOF>");
	# Content-Type HTML is my que to insert the SMN menu
	# but only if the msg is inbound!
	if ($whole_msg=~s/(.*)(<\/body>.+)/$1$SMN_foot$2/ios) {
			&msg_txt("-25> SMN footer inserted before $2");
		}

	return $whole_msg;
} # End of add SMN menu





#>----------------------------------------------------------------------------
sub makedomainlist{
	my ($dbh) = @_;
	my $domains='|';
	# should look like: '|spammenot.com|fieldsfamily.net|delicateflower.com|'
	&msg_txt("Looking for local domains in the database");

	##http://www.perl.com/pub/a/1999/10/DBI.html
	my $sth = $dbh->prepare("SELECT FQDN,MX_SERVER 
				 FROM domains 
				 where STATUS=?") 
				 or die &msg_txt("Couldn't prepare SQL err: $dbh->errstr");

	$sth->execute("OK") or die "Couldn't execute SQL err: " . $dbh->errstr;

	while (my $ref = $sth->fetchrow_hashref()) {
		$domains .= $ref->{'FQDN'};
		$domains .= "|";
		&msg_txt("   Found and added domain: $ref->{'FQDN'}");
		}

	if ($sth->rows == 0) {
    	&msg_txt("No domains matched!");
        }

	
	$sth->finish();

   return $domains;

} # end of makedomainlist

#>----------------------------------------------------------------------------
sub log_xheaders {
	my ($xmailer,$xheader,$xvalue,$dbh) = @_;
	# X-Mailer should look like: 'Microsoft Outlook Express 6.00.2800.1158'
	&msg_txt("Xmailer=$mailer Xheader=$xheader Val=$xvalue");

	my $sth = $dbh->prepare("UPDATE log_headers 
							 SET COUNTED=COUNTED+1 
						 	where XMAILER=?
						 	and XHEADER=? 
						 	and VALUE=?") 
				 or die &msg_txt("Couldn't prepare SQL err: $dbh->errstr");

	$sth->execute($xmailer,$xheader,$xvalue) or die;

	if ($sth->rows == 0) {
			my $sth = $dbh->prepare("INSERT INTO log_headers 
									 (XMAILER,XHEADER,VALUE,COUNTED) values(?,?,?,?)") 
			or die &msg_txt("Couldn't prepare SQL err: $dbh->errstr");

			$sth->execute($xmailer,$xheader,$xvalue,1) or die;
			}
	
	$sth->finish();

} #end of log_xheaders



#>----------------------------------------------------------------------------

sub clean_name {
	local($_)=@_;				# Put the input into local standard in
	$_="\L$_";					# make STDIN all lower case (\L=all following letters)
	# Should test for 'to:<'
	# Should test for 'to: <'
	# Should test for 'to:'
	# Should test for 'to: '
	# Should test for ':' as a delimter as per rfc2821 sec: 4.1.1.3
	#    Like this <RCPT TO:<@hosta.int,@jkl.org:userc@d.bar.org>

	if ($_ =~ /\<[0-9a-zA-Z\.\-\_]+\@[0-9a-zA-Z\.\-\_]>+$/) {
		# Is there a real < > pair?
		# exp says yes!  $1 should now contain it.
		&msg_txt("3:$_/$1");
	}

	&msg_txt("1:$_");
	$_=~s/^to://;			## Trim off "to:", ^=start of line
	$_=~s/^ //;			## Trim off " ", ^=start of line
	&msg_txt("2:$_");

		# no valid < > pair found, mooooving on


#	$_=~s/^\<//);			## Trim off "<", ^=start of line
#	$_=~s/>$//;			## Trim off the > character, $=end of line


	return $_
} #End of clean_name


#>----------------------------------------------------------------------------
sub censor_text {
	# http://aspn.activestate.com/ASPN/Cookbook/Rx/Recipe/59810
} #End of censor


#>----------------------------------------------------------------------------
sub ValidEmailAddr { #check if e-mail address format is valid
  my ($mail) = @_;                                                  #in form name@host
	&msg_txt("-38>Inside Validate email: $mail");

  return 0 if ( $mail !~ /^[0-9a-zA-Z\.\-\_\:\+\@\#\=\!\$\%\&\'\*\/\?\^\`\{\}\|\~]+\@([0-9a-zA-Z\.\-]+)$/ ); #characters allowed on name: 0-9a-Z-._ #+ on host: 0-9a-Z-. on between: @
  my $sender_domain = $1;
  return 0 if ( $mail =~ /^[^0-9a-zA-Z]|[^0-9a-zA-Z]$/);             #must start or end with alpha or num
  return 0 if ( $mail !~ /([0-9a-zA-Z]{1})\@./ );                    #name must end with alpha or num
  return 0 if ( $mail !~ /.\@([0-9a-zA-Z]{1})/ );                    #host must start with alpha or num
  return 0 if ( $mail =~ /.\.\-.|.\-\..|.\.\..|.\-\-./g );           #pair .- or -. or -- or .. not allowed
  return 0 if ( $mail =~ /.\.\_.|.\-\_.|.\_\..|.\_\-.|.\_\_./g );    #pair ._ or -_ or _. or _- or __ not allowed
  return 0 if ( $mail !~ /\.([a-zA-Z]{2,3})$/ );                     #host must end with '.' plus 2 or 3 alpha for TopLevelDomain (MUST be modified in future!)

# NOTE! An email like auto-reply@192.168.11.1 may NOT have an MX record.
#  my $res  = Net::DNS::Resolver->new;
#  my @mx   = mx($res, $sender_domain);
#  if (@mx) {
#      foreach $rr (@mx) {
#          &msg_txt("MX for $sender_domain is ",$rr->preference, " ", $rr->exchange );
#      }
#  } # end if MX

#  my $mx_count = scalar(@mx);
#  if ($mx_count==0){
	#domain must have valid mx record
#	&msg_txt("-38I> No valid MX record for $sender_domain");
#	return 0;
#  }else{
	return 1;
#  }

} #End of ValidEmailAddr

#>----------------------------------------------------------------------------
sub make_directories {
	my $pathe;
	while (@_) {
		my $part = pop(@_);
		if ($part!~/^\//) {
			$part = "/$part";			## add the leading slash if it isnt there
			}
		$pathe = "$pathe$part";

		if (!(chdir $pathe)) {
			## Could not change into this directory. Oh well, let's create it.
			if (!(mkdir $pathe,0770)) {
				&msg_txt("Fatal Problem: cannot create $pathe to store msgs in");
				return 0;
			}
		}
	}
	# We successfully made all the dirs.
	return 1;
}


#>----------------------------------------------------------------------------
sub base64 {
 my ($sample)=@_;
 $sample =~ tr|A-Za-z0-9+=/||cd;            # remove non-base64 chars
 $sample =~ s/=+$//;                        # remove padding
 $sample =~ tr|A-Za-z0-9+/| -_|;            # convert to uuencoded format
 local ($len) = sprintf('%c',32 + length($sample)*3/4); # compute length byte
 my $result = unpack("u", $len . $sample );    # uudecode
 return $result;
} #End of base64


#>----------------------------------------------------------------------------

sub log_session {
	&msg_txt("-90> log2SQL? $sender->{log2sql}");

	if ($sender->{log2sql}!~/(POP3|ALL)/) {
		return;
	}

	$time_is = build_myqsl_time;

	&msg_txt("-98> DBG=$sender->{debug}/$sender->{log2sql} Inserting session into MySQL log_session, Exiting");

	##http://www.perl.com/pub/a/1999/10/DBI.html

	my $sth = $dbh->prepare("INSERT INTO log_sessions 
							 (CUST_ID,_TIMESTAMP,SERVICE,TRANSCRIPT) values(?,?,?,?)") 
	or die &log(1,"Couldn't prepare SQL err: $dbh->errstr");

	$sth->execute($sender->{cust_id},$time_is,'POP3',$session_log) or die "Cannot execute SQL INSERT";
	
	$sth->finish();

} #end log_session

#>----------------------------------------------------------------------------

sub increment_TPOL_counter {
	my ($us,$sender,$dbh) = @_;
	my ($trusted,$rules,$sth,$rec,$domain)

	## Now we need to check for extenuating cirumstances in the TPOL db
	&msg_txt("Updating TPOL combo: $us + $sender->{fqaddress}");

	# Now retrieve data from the table.
	$sth = $dbh->prepare("UPDATE TPoL 
				 		WHERE OUR_ADDRESS=?
				 		 and THEIR_ADDRESS=?");
	$sth->execute($us,$sender->{fqaddress});
	
	if (($sth->rows) >= 1) {
    	&msg_txt("We have a winner!");
		my $rec=$sth->fetchrow_hashref();
			$trusted=$rec->{'TRUSTED'};
			$rules=$rec->{'RULE'};
	    }
	$sth->finish();



} #end increment_TPOL_counter

#>----------------------------------------------------------------------------
sub CR_counter_decrement {
	my ($us,$sender,$dbh) = @_;
	my ($sth,$domain);
	
	# Now update this pair counter for Challenge Response
	$sth = $dbh->prepare("UPDATE TPoL 
				SET CR_COUNT = CR_COUNT-1 
				WHERE OUR_ADDRESS=?
				 and THEIR_ADDRESS=?");
	$sth->execute($us->{fqaddress},$sender->{fqaddress});
	$sth->finish();
	
} #end of CR_counter_decrement

#>----------------------------------------------------------------------------
sub bounce_localspoof {
	my ($sender,$spoofed,$err)=@_;
	my $body,$tempname;

	# 1) load text from database
	# 2) search/replace for three pieces of info
	# 3) insert into local mail directory

	my $sth = $dbh->prepare("SELECT BODY 
				 FROM text_automated 
				 where TITLE=?") 
				 or die &log(1,"Couldn't prepare SQL err: $dbh->errstr");

	$sth->execute('SPOOF-1') or die "Couldn't execute SQL err: " . $dbh->errstr;

	if (my $ref = $sth->fetchrow_hashref()) {
		$body = $ref->{'BODY'};
		&msg_txt("Found msg body for the bounce msg");
		}

	if ($sth->rows == 0) {
		$domain = "mail.$domain";
		&msg_txt("No msg body found for the bouce msg");
        }

	$sth->finish();
	
	#make this string: 'Fri, 12 Dec 2003 07:26:35 -0600'
	my $dated = gmtime()." GMT0";
	
	# 2) search/replace for each piece of info
	$body=~s/\[date\]/$dated/iosg;					# Replace [date] with, um, now
	$body=~s/\[sender\]/$sender->{fqaddress}/iosg;	# Replace [recip] with the actual email address
	$body=~s/\[spoofed\]/$spoofed/iosg;				# Replace [spoofed] with the fake email address
	$body=~s/\[recip\]/$to/iosg;					# Replace [recip] with the actual email address
	$body=~s/\[subject\]/$subject/iosg;				# Replace [subject] with the actual subject
	$body=~s/\[reason\]/$err/iosg;					# Replace [reason] with the error string

	# No longer need to do this , since we switched to using $sender throughout Jan07/04
	# 3) insert into local mail directory
	# $sender = lookup4auth($sender->{fqaddress},$dbh);

	my $start_time=time;
	$tempname="$start_time.P$$.$I_AM";	## $$ is the PID, http://cr.yp.to/proto/maildir.html

	my $deliver_dir="$base_maildir/$sender->{domain}/$sender->{base}/new/$tempname";
	unless(open(TMP,">$deliver_dir")) {
		# go make the satupid directories. reversed order to save code
		if(make_directories('new',$sender->{base},$sender->{domain},$base_maildir)) {
 			unless(open(TMP,">$deliver_dir")) {
   				&msg_txt("failed to open $deliver_dir");
			} #End second unless open
		} #End if make Dir
  	} #End first unless open

	&msg_txt("writing to dir: $deliver_dir");
  	unless (print TMP "$body") {		# dump existing content into file
  		print "failed to write to $deliver_dir\n";
		}

	close TMP;					# make it so!

} #end of bounce_localspoof


#>----------------------------------------------------------------------------
sub bounce_figlet {
	my ($sender,$adr,$text_id)=@_;
	#my ($sender,$spoofed,$err)=@_;
	my $body,$tempname;

	# 1) load text from database
	# 2) search/replace for three pieces of info
	# 3) insert into local mail directory

	my $sth = $dbh->prepare("SELECT BODY 
				 FROM text_automated 
				 where TITLE=?") 
				 or die &log(1,"Couldn't prepare SQL err: $dbh->errstr");

	$sth->execute($text_id) or die "Couldn't execute SQL err: " . $dbh->errstr;

	if (my $ref = $sth->fetchrow_hashref()) {
		$body = $ref->{'BODY'};
		&msg_txt("Found msg body for the $text_id msg");
		#print "Found msg body for the $text_id msg\n";
		}

	if ($sth->rows == 0) {
		$domain = "mail.$domain";
		&msg_txt("No msg body found for the bouce msg");
        }

	$sth->finish();
	

	# 2) make the new bits
	my $dated = gmtime()." GMT0";			#make this string: 'Fri, 12 Dec 2003 07:26:35 -0600'
	$figlet_word = "baby";
	$figlet = $figlet_word;

	# 3) search/replace for each piece of info
	$body=~s/\[date\]/$dated/iosg;					# Replace [date] with, um, now
	$body=~s/\[sender\]/$sender->{fqaddress}/iosg;	# Replace [recip] with the actual email address
	$body=~s/\[recip\]/$adr/iosg;					# Replace [recip] with the actual email address
	$body=~s/\[figlet\]/$figlet/iosg;				# Replace [subject] with the actual subject

	my $now_time=time;
	$tempname="$now_time.P$$.$I_AM";	## $$ is the PID, http://cr.yp.to/proto/maildir.html

	my $deliver_dir="$base_maildir/$sender->{domain}/$sender->{base}/new/$tempname";
	unless(open(TMP,">$deliver_dir")) {
		# go make the satupid directories. reversed order to save code
		if(make_directories('new',$sender->{base},$sender->{domain},$base_maildir)) {
 			unless(open(TMP,">$deliver_dir")) {
   				&msg_txt("failed to open $deliver_dir");
			} #End second unless open
		} #End if make Dir
  	} #End first unless open

	&msg_txt("writing to dir: $deliver_dir");
  	unless (print TMP "$body") {		# dump existing content into file
  		print "failed to write to $deliver_dir\n";
		}

	close TMP;					# make it so!

} #end of bounce_figlet


#>----------------------------------------------------------------------------

sub build_mysql_time {
	my $time_is,@t;

	@t = localtime;
#	my $ss=$t[0];
#	my $mm=$t[1];
#	my $hh=$t[2];
#	my $dd=$t[3];
#	my $MM=$t[4];
#	my $YYYY=$t[5];
	$t[4]=$t[4]+1;
	$t[5]=$t[5]+1900;
	$time_is = $t[5].$t[4].$t[3].$t[2].$t[1].$t[0];
	&msg_txt("-216> made MySQL time: $time_is");

	return $time_is;
}
#>----------------------------------------------------------------------------



sub write_PID {
	# We write out the PID so rcspammenot script can find it
	# and kill/start/etc.

	open(PIDfile,">>$PID_file");	## Setup the default PID file
	select PIDfile; $|=1; 			# make unbuffered so it will write immediately
	print PIDfile "$$";				# write our current PID
	close PIDfile;					# all done!

} #end write_PID

#>----------------------------------------------------------------------------
sub deliver {
 $to=join(' ',@to);
 $to=~s/'//g;
 $to=~s/(\S+)/'$1'/g;
 &msg_txt("$sender->{fqaddress} $bytes bytes $auth $to");
 if($viruscheck && $bytes > $smallestvirus) {
  $subject=~s/'/"/g;
  system "($viruscheck $tempname '$sender->{fqaddress}' '$subject'; $inject '-f$sender->{fqaddress}' $to <$tempname; rm $tempname) ";
 } else {
  system "($inject '-f$sender->{fqaddress}' $to <$tempname >>$log.log; rm $tempname) ";
 }
} #End of deliver

#>----------------------------------------------------------------------------

sub directory_OK {
	# This Routine makes directories, just in case they don't already exist.
	my $pathe;
	while (@_) {
		my $part = pop(@_);
		if ($part!~/^\//) {
			$part = "/$part";			## add the leading slash if it isnt there
			}
		$pathe = "$pathe$part";

		if (!(chdir $pathe)) {
			## Could not change into this directory. Oh well, let's create it.
			if (!(mkdir $pathe,0770)) {
				&msg_txt("Fatal Problem: cannot create $pathe to store msgs in");
				return 0;
			}
		}
	} #end of while
	
	# We successfully made all the dirs.
	return 1;
} #end of make_directories


#>----------------------------------------------------------------------------

sub msg_txt {
	my ($callNow, $microseconds) = gettimeofday;
	$lastLogTime = $callNow;	## Make a note, we logged in this second.
	$lastLogCount = 0;		## Reset the counter, since it is not the same second as last logging time...

	my $temp = shift;
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)=localtime(time);
	my $elapsedT = $callNow - $callStarted;
	my $tNow = sprintf("%02d:%02d:%02d \(%04d-$lastLogCount\)", $hour, $min, $sec, $elapsedT);
	my $entireLine = "$$ $tNow $temp ";

	# Save all loggable	stuff to a able, so	it can be optionally output	
	# $session_log .=	"$entireLine\r\n";

	if($mydebuglevel>=3) {
		print MSG_TXT "$entireLine\n";
	}

	# Save all loggable	stuff to a variable, so	it can be optionally output	
	$session_log .=	"$entireLine\r\n";

} #end of msg_txt

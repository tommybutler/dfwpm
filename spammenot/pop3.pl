#!/usr/local/bin/perl
use	Socket;	
use	Fcntl ':flock';	
use	IO::Handle;	
use	IO::Socket;	
#use	Carp;
use	DBI();


$version = "v0.3";

#Copyright (c) 1999 David Nicol <davidnicol@acm.org>. License is	
#granted to modify and install as needed, with the expectation that
#this copyright notice will remain.
# thanks to	Mark Lipscombe's frustrating experiments with Microsoft	
# Outlook which	is more	demanding in such things than Mozilla.
#
#implementation	goals:	
#
#	be	in standard	perl 5
#	implement rfc1725
#	run	standalone (from inetd can be done by crippling	this easily)
#	read mail out of a directory where is has been placed one 
#	message	per	file (such as a	MailDir)
#	Delete mail	directly from the directory
#After editing the user specific	portions,
#<nohup	popdaemon &	> can be added to rc.local.	
#This program is a full implementation of rfc 1725,
#with an adjustment made to unsplit header lines so that	
#Netscape Communicator will not drop the connection when	
#it gets a message-id that is too long.

$db_host = 'localhost';
$db_port = '3306';
$db_name = 'spammenot';
$db_user = '';
$db_pass = '';

$MLEM="\r\n.\r\n";		#Multi Line End Marker

#$PID_file = '/var/run/spammenot_pop3.pid';	## let outside world know where you are

# the maildir parent directory
# /domain/user/new/	is added to	it

$base_maildir="/srv/email";

#########################################################

$msglog="/var/log/spammenot/pop3_$$.log";	## your debug msg file location
# '/var/log/spammenot_msgs.log';		 

$prglog='/var/log/spammenot/pop3_daemon.log';	## your log file location
# '/var/log/spammenot_pop3d.log';		 

$timeout = 90;				# if there is no activity for xx seconds, dump the caller

$msg_2big2log = 1200;		# At this many lines, stop copying lines into memory for logging.

$mydebuglevel=0;## Interactive debugger	(note, incoming	email addresses	can	over ride this)
				## 0 = none	or quiet
				## 1 = normal -	startup, errors	and	shutdown
				## 2 = normal +	more setup details
				## 3 = normal +	individual transaction result
				## 9 = EVERYTHING!!!



if($mydebuglevel>=9) {
	open(MSG_TXT,">>$msglog");
	select MSG_TXT;	$|=1;					# make unbuffered
}

sub	msg_txt	{
	local(@p)=@_;					## Save	the	input to a local variable
	local($time,$level);
#	$level=shift(@p);

	# Realtime text	logging	
	#if(($mydebuglevel>=9) && ($sender->{log2disk}=~/POP3|ALL/)) {
	if($mydebuglevel>=9) {
		$time=localtime;
		print MSG_TXT "$time $$ @p\n";
	}

	# Save all loggable	stuff to a variable, so	it can be optionally output	
	$session_log .=	"@p\r\n";
}


sub	input_txt {
	my $temp = shift(@_);
	my $time=localtime;
	if (length($temp)>100) {	## Simple check for buffer overflow attempt
		&log("\nHouston, length problem from $remote_hostname<$remote_ip>:\n<$temp>");
	}
	$temp =~ s/\r/\(cr\)/g;		## if there	is a carriage return, change it
	$temp =~ s/\n/\(lf\)/g;		## if there	is a line feed,	change it

	# Save all loggable	stuff to a variable, so	it can be optionally output	
	$session_log .=	"clt: $temp\n";

	#if(($mydebuglevel>=2) && ($sender->{log2disk}=~/(POP3|ALL)/)) {
	if($mydebuglevel>=2) {
		print MSG_TXT "$time $$ clt: $temp\n";
	}
} #End input_txt


sub output_txt {
	my $p =	shift(@_);
	#$p =~ s/\ \f+/ /g;				## change whitespace [ \r\n\f] to spaces
	#$p =~ s/\s+$//g;				## Trim trailing spaces
	if ($p=~/\r\n$/){
		#Do nothing, it is OK
	}else{
		$p .= "\r\n";				# Append a CRLF pair
	}
	#elsif($p=~/\n$/){
	#	$p=~s/\n$/\r\n/i;			# what if just a LF?  make it CRLF
	#}
	print STDOUT "$p";	

	$p =~ s/\r/\(cr\)/g;		## if there	is a carriage return, change it
	$p =~ s/\n/\(lf\)/g;		## if there	is a line feed,	change it

	# Save all loggable	stuff to a variable, so	it can be optionally output	
	if($mydebuglevel) {
		$session_log .=	"srv: $p\n";
	}

	#if(($mydebuglevel>=2) && ($sender->{log2disk}=~/(POP3|ALL)/)) {
	if($mydebuglevel>=2) {
		my $time=localtime;
		print MSG_TXT "$time $$ srv: $p\n";
	}

	alarm $timeout;	
}

$SIG{ALRM} = sub {
	# flush the buffers, MySQL write, etc.
	&msg_txt("Alarm: $timeout sec timer expired, exiting");
	&log_session;
	die "alarm or timeout\n"
	};

sub SockData($){
	#return;
		my $theirsockaddr	= getpeername(STDIN);
		my ($port, $iaddr)	= unpack_sockaddr_in($theirsockaddr);
		my $theirhostname	= gethostbyaddr($iaddr, AF_INET);
		my $theirstraddr	= inet_ntoa($iaddr);
		return $theirhostname,$theirstraddr;
}

#>-------------------------------------------
$SIG{TERM} = \&shut_it_all_down;
$SIG{QUIT} = \&shut_it_all_down;

#&write_PID;			## Set the PID file to current PID

select(STDOUT);$|=1;

&server;			# setup MySQL, etc.
&session;			# do all the work
&shut_it_all_down;	# At least I think this should go here....
exit;				# should be non-functional, but just in case.

#>--------------------------------------------------------------------
sub server {
	print MSG_TXT "\n\n";		#send a few blank lines to the text file

	#make this string: 'Fri, 12 Dec 2003 07:26:35 -0600'
	$time_is = gmtime()." GMT0";

	&msg_txt("POP3 $time_is");
	&msg_txt("POP3 srv ahoy! connecitng to mySQL - fingers crossed");
	
	#======================= [	open_dbi ] =======================
	# Connect to the requested	server,	otherwise dont start the daemon(s)
	# http://perl.about.com/library/weekly/aa090803a.htm
	$dbh = DBI->connect("DBI:mysql:$db_name:$db_host","$db_user","$db_pass",{'RaiseError' => 1});
	#======================= [	open_dbi ] =======================

	if ($dbh) {
		&msg_txt("MYSQL OK");
	}else {
		&msg_txt("MYSQL NOT OK: $dbh/$RaiseError");
		die;
	}
	
	# get the IP address of STDIN
	($remote_hostname,$remote_ip)=SockData(STDIN);

	#my $pid;
	&msg_txt("Connection from $remote_hostname($remote_ip)");
	
} #end of server

sub session{
	# IF we get here... I am the child! -- go to work
	&msg_txt("-09> here we are in a new session $$");

	#$|=1;				# set no waiting on input
	#STDIN = STDIN;	# set client to use STDIN (from inetd)

	&msg_txt("-10> New Connection $remote_hostname($remote_ip) PID=$$");
	if (&AUTHORIZATION) {
		&msg_txt("-20> exited from AUTHORIZATION state OK");
		if(&TRANSACTION) {
			&msg_txt("-30> exited from TRANSACTION state OK");
			if (&UPDATE) {
				&msg_txt("-40> exited from UPDATE state OK");
			}
		}
	}
	# Do we dump $session_log into the SQL table?
	&log_session;
	&msg_txt("-99> Done! Exiting\n\n");
	close MSG_TXT;
	exit;

} #end of sub session

#############################################################################
##
##				End of main program
##
#############################################################################

sub shut_it_all_down {
 ## called on INT to clean up a bit
 # $dbh = shift;
 # STDIN = shift;

 close(SERVER);
 close STDIN;
 unlink $PID_file;
 $dbh->disconnect();
 #&log(1,"Exiting normally");
 # If we wanted to send some text out, do like this die 'Exiting Normally on INT';
 print "byebye\n";
 exit;
}

sub	AUTHORIZATION{
	my ($tmp);
	&output_txt("+OK SPAMMENOT POP3 $version $remote_hostname($remote_ip)".scalar(localtime));

	while (<STDIN>) {
		&input_txt("$_");

		@p=split(' ',$_);			# split all parms into a hash, "space" delimted
 		$arg=shift(@p);				# load just the first parameter
 		$arg="\L$arg";				# make arg all lower case (\L=all following letters)

		#Maybe a good case statement?
		if($arg eq 'quit') {last;}
		elsif($arg eq 'user') {&pop_user(@p);}
		elsif($arg eq 'pass') {pop_pass(@p);}
		else {
			$strikes += 1;
			&output_txt("-ERR whatever");
		}		

		if ($auth|($strikes>3)) {
			last;
		}
	} #end while

	if ($strikes>3) {
		&output_txt("+ERR too many guesses");
		return 0;
		}

	if (!$auth) {
		# there was a problem.
		&output_txt("+OK whatever. bye");
		return 0;
		}

	$MailDir = "$base_maildir/$sender->{domain}/$sender->{base}/new";
	unless (-d $MailDir	and	opendir	DIR, $MailDir ){
		&msg_txt("MailDir problem: $MailDir");
		return 0;
	}

	chdir $MailDir;	

	@messages =	grep {!/PopDaemonLock/}	(grep {-f $_} (readdir DIR));

	# Lock the maildrop	
	open LOCK, ">>.PopDaemonLock";
	unless(flock LOCK,LOCK_EX|LOCK_NB){	
		&msg_txt("Maildrop contains ".scalar(@messages)." but it is already locked: perhaps we are still deleting? Please try again in a few minutes");
		return 0;
	}

	&output_txt("+OK $sender->{fqaddress} has ".scalar(@messages)." messages");	
	return 1;
} #end of AUTHORIZATION




sub pop_user {
	my $p=shift(@_);
	&msg_txt("-11> looking up USER: $p");		## prints their	authorization in plain text

	if ($p=~/([0-9a-zA-Z\-\.\@]+)/i) {
		$sender	= lookup4auth($1,$dbh);
		&msg_txt("-15> Passed out: $sender->{status}/$sender->{pw}");		## prints their	authorization in plain text
		if ($sender->{status} ne "OK") {
			&output_txt("+ERR AUTH Failed, missing or not POP enabled - call us!");
			$strikes +=1;
		} else {
			&output_txt("+OK User name ($sender->{fqaddress}) ok. Password, please.");
		}
	}
} #end of sub pop_user

sub pop_pass{	
	my $p=shift(@_);
	&msg_txt("-16> PASS command input: $p");		## prints their	authorization in plain text
	if($p=~/([0-9a-zA-Z\-\+\.\@\!\#\$\%\^\&\*\|]+)/i) {
		# Allow extra characters for passwords above
		$p = $1;
		$p=~s/\s+$//g;				# Trim trailing spaces
		if ($sender->{pw} eq $p){
			$auth = 1;
			&msg_txt("-17> I judge MATCH! Pass: known=$sender->{pw} incoming=$p");
		}else{
			&msg_txt("-18> I judge bad donkey! Pass: known=$sender->{pw}	incoming=$p");
			&output_txt("+ERR AUTH failed");
			$strikes +=1;
		}
	}
} #end of sub pop_pass
	

sub	TRANSACTION{
	my $arg;
	## Does anyone care we are inside tranasction phase?

	%deletia = ();		# Hash of msgs?

	while (<STDIN>) {
		&input_txt("$_");
		$Data = $_;					# for compat until I fix everything

		@p=split(' ',$_);			# split all parms into a hash, "space" delimted
 		$arg=shift(@p);				# load just the first parameter
 		$arg="\L$arg";				# make arg all lower case (\L=all following letters)

		#Maybe a good case statement?
		if($arg eq 'quit') {last;}
		elsif($arg eq 'stat') {&_STAT;}
		elsif($arg eq 'list') {&LIST;}
		elsif($arg eq 'retr') {&RETR;}
		elsif($arg eq 'dele') {&DELE;}
		elsif($arg eq 'noop') {&NOOP;}
		elsif($arg eq 'rset') {&RSET;}
		elsif($arg eq 'top') {&TOP;}		# optional command (rfc 1725)
		elsif($arg eq 'uidl') {&UIDL;}		# optional command (rfc 1725)
		else {
			$strikes += 1;
			&output_txt("+ERR I do not know <$arg>");
		}		

		if ($strikes>3) {
			last;
		}
	} #end while

	if ($strikes>3) {
		&output_txt("+ERR too many guesses");
		return 0;
		}

	&output_txt("+OK $sender->{fqaddress} has ".scalar(@messages)." messages");	
	return 1;
} #end of TRANSACTION


sub	_STAT{
	alarm 0;	#who knows how long	reading	the	dir	will take?
	$mm	= 0;
	$nn	= scalar(@messages);
	foreach	$msg (@messages){	
		$mm	+= -s "$msg";	
	};
	&output_txt("+OK $nn $mm");
};

sub	List($){

	my $msg = $messages[$_[0]-1];	
	return if $deletia{$msg};	
	&output_txt("$_[0] ".(-s $msg));
	#print STDIN $_[0],' ',(-s $msg)."\r\n";	
	#print "S: ", $_[0],' ',(-s $msg)."\r\n";
	alarm $timeout;	

};

sub	LIST{
	if (($d) = $Data =~/(\d+)/){
		unless(defined($msg = $messages[$d-1])){
			&output_txt("+ERR no message number $d");	
			return;	
		};
		if ($deletia{$msg}){
			&output_txt("+ERR message $d deleted");
			return;	
		};
		&output_txt("+OK Listing $d");
		List $d;
		return;	
	};
	&output_txt("+OK Listing");
	$nn	= scalar(@messages);
	foreach	$d (1..$nn){
		List $d;
	};
	&output_txt(".\r\n");
};

sub	RETR{
	my $lines;
	unless (($d) = $Data =~/(\d+)/){
		&output_txt("+ERR message number required");
		return;	
	};
	$msg = $messages[$d-1];
	unless(defined($msg)){
		&output_txt("+ERR no message $d");
		return;	
	};
	if ($deletia{$msg}){
		&output_txt("+ERR message $d deleted already");
		return;	
	};
	&output_txt("+OK Here comes ".(-s $msg)." bytes");
	alarm 0;
	open MESSAGE,"<$msg";
	my $msg_length=0;				# Count the 5 termination characters?
	#while (defined($line = <MESSAGE>)){
	while (<MESSAGE>){
		$line = $_;
		#&msg_txt("-266> lines=$lines, <$line>");

		if ($lines!=$msg_2big2log) {
			$lines +=1;
		}else{
			&msg_txt("MSG($lines) too large to store in memory, observing radio silence until it is all sent");
			$mydebuglevel = 0;						## Temporarily disable logging
			$lines +=1;
		} #end if loggable
		if ($line =~ m/^\.\s*$/) {
			&msg_txt("  hey!!!, this line was just a dot and spaces: <$line>");
			# if line is just a dot and spaces (why?)
			$msg_length += 2;
			&output_txt("..");
		}else{
			$msg_length +=(length($line));
			&output_txt("$line");
		} #end if dot
	};

	$mydebuglevel = $sender->{debug};				## Restore logging parm
	&output_txt("$MLEM");							## pads message with final CRLF.CRLF
	#&output_txt("+OK");
	&msg_txt("-26> Im back, $lines lines transmitted ($msg_length bytes)");
	alarm $timeout;	
};


sub	DELE{
	unless (($d) = $Data =~/(\d+)/){
		&output_txt("+ERR message number required");
		return;	
	};
	$msg = $messages[$d-1];
	unless(defined($msg)){
		&output_txt("+ERR no message $d");
		return;	
	};
	if ($deletia{$msg}){
		&output_txt("+ERR message $d deleted already");
		return;	
	};
	$deletia{$msg} = 1;
	&output_txt("+OK message $d ($msg) marked");
};

sub	NOOP{
	&output_txt("+OK");
};

sub	RSET{
	%deletia=();
	&output_txt("+OK biz buzz");
};

sub	TOP{
	unless (($d,$n)	= $Data	=~/(\d+) (\d+)/){
		&output_txt("+ERR RFC1725 says TWO numbers here");
		$strikes += 1;
		return;	
	};
	#$msg = $msgessages[$d-1];
	$msg = $messages[$d-1];
	unless(defined($msg)){
		&output_txt("+ERR no message $d");
		return;	
	};
	if ($deletia{$msg}){
		&output_txt("+ERR message $d deleted already");
		return;	
	};
	&output_txt("+OK Here come headers for message $d ($msg)");
	alarm 0;
	open MESSAGE,"<$msg";	
	my $counter = 0;
	my $outofheaders = 0;
	while (defined($line = <MESSAGE>)){
		
		if($outofheaders) {
			# this is the first line after the headers, so start counting!
			$counter += 1;
			if($counter>$n) {
				# OK, we have just exceeded the number of lines requested.
				last;
				}
			}

		if(($line=~/^\r\n$|^\n$/)) {	# when we hit a blank line the headers are supposed to be over.
			$outofheaders=1;
			}
		
		&output_txt(".") if $line =~ m/^\.\s*\Z/;		## escape single dots (Don't think this is correct)

		# mush first line of oversplit header (for mozilla)	
		if (($HB) =	$line =~ m/^(\S+\:)\s+\Z/){	
			$line =	<MESSAGE>;
			$line =~ s/^\s+//;
			$line =	"$HB $line";
			};

		&output_txt("$line");
		#$counter = $n if ($counter < 0 and not(	$line =~ /\w/));
	};
	&output_txt("$MLEM");
	alarm $timeout;	
};

sub	UIDL{
	if (($d) = $Data =~/(\d+)/){
		unless(defined($msg = $messages[$d-1])){
			&output_txt("+ERR no message number $d");	
			return;	
		};
		if ($deletia{$msg}){
			&output_txt("+ERR message $d deleted");
			return;	
		};
		&output_txt("+OK $d $msg");
		return;	
	};
	&output_txt("+OK Listing file names");
	alarm 0;
	$nn	= scalar(@messages);
	foreach	$d (1..$nn){
		&output_txt("$d $messages[$d-1]\r\n");	
	};
	alarm $timeout;	
	&output_txt(".\r\n");	# already have a leading CRLF from
							# the OK or	the	last message line.
};


sub	UPDATE{	

	@DeleteMe =	keys %deletia;
	while($Target =	shift @DeleteMe){
	# print "Trying to unlink $Target\n";	
		
	-f $Target or (&msg_txt("-35> cannot delete <$Target>, is not a file"),next);	
		unlink $Target and &msg_txt("-36> deleted $Target");
	};

	return 1;
};


#>----------------------------------------------------------------------------
sub	lookup4auth{
	my ($address,$dbh) = @_;
	my $tmp	= {} ;			# define tmp as	an array

	&msg_txt("-12a> user <$address> <$dbh>");

	if (length($address)<8) {
		&msg_txt("-13> user account must be at least 8 characters! <$address>");
		$tmp->{pw}="rejected";
		return $tmp;
	}
	
	##http://www.perl.com/pub/a/1999/10/DBI.html
	my $sth	= $dbh->prepare('SELECT	* 
				 FROM accounts 
				 where FQ_ADDRESS=?') 
				 or	die	&msg_txt("Couldn't prepare SQL err:	$dbh->errstr");	

	$sth->execute($address)	or die "Couldn't execute SQL err: "	. $dbh->errstr;	

	if (my $ref	= $sth->fetchrow_hashref()) {	
		$tmp->{fqaddress}		= $ref->{'FQ_ADDRESS'};;
		$tmp->{pw}				= $ref->{'PASSW'};
		$tmp->{status}			= $ref->{'STATUS'};	
		$tmp->{base}			= $ref->{'ADDRESS'};
		$tmp->{domain}			= $ref->{'DOMAIN'};
		$tmp->{account_id}		= $ref->{'ACCOUNT_ID'};
		$tmp->{cust_id}			= $ref->{'CUST_ID'};
		$tmp->{rules}			= $ref->{'RULES'};
		$tmp->{debug}			= $ref->{'DEBUG'};
		$tmp->{log2sql}			= $ref->{'LOG2SQL'};
		$tmp->{log2disk}		= $ref->{'LOG2DISK'};
		&msg_txt("-12b> Found a row: addy=$tmp->{fqaddress} pw=$tmp->{pw} stat=$tmp->{status}	max_recip=$tmp->{max_recipients} dbg=$sender->{debug} rules=$tmp->{rules}");
	} else{
		#if ($sth->rows == 0) {
		&msg_txt("-14> No base accounts matched `$address'");	
	}

	$sth->finish();

   if ($tmp->{status} ne 'OK'){$tmp->{pw}="rejected";}
   
   return $tmp;

} #	end	of lookup4auth

#>----------------------------------------------------------------------------

sub log_session {
	&msg_txt("-90> log2SQL? $sender->{log2sql}");

	if ($sender->{log2sql}!~/(POP3|ALL)/) {
		return;
	}

	my $time_is = build_mysql_time();

	&msg_txt("-98> DBG=$sender->{debug}/$sender->{log2sql} Inserting session into MySQL log_session, Exiting");

	##http://www.perl.com/pub/a/1999/10/DBI.html

	my $sth = $dbh->prepare("INSERT INTO log_sessions 
							 (CUST_ID,_TIMESTAMP,SERVICE,TRANSCRIPT) values(?,?,?,?)") 
	or die &log(1,"Couldn't prepare SQL err: $dbh->errstr");

	$sth->execute($sender->{cust_id},$time_is,'POP3',$session_log) or sub {
		&msg_txt("-98b> Cannot execute SQL INSERT");
		#Log to disk!
		};
	
	$sth->finish();

} #end log_session

#>----------------------------------------------------------------------------

sub build_mysql_time {
	my $time_is,@t;

	@t = gmtime;
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

	unlink $PID_file;
	open(PIDfile,">>$PID_file");	## Setup the default PID file
	select PIDfile; $|=1; 			# make unbuffered so it will write immediately
	print PIDfile "$$";				# write our current PID
	close PIDfile;					# all done!

} #end write_PID
__END__	

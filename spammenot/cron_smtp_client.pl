#!/usr/bin/perl

#use strict;
use DBI();
use Net::DNS;
use Net::SMTP;	## Only for acting as a client to other email servers...
use File::Copy;

$version = "v0.3";


#include ./spammenot_common.pl

# Run this monkey looking for files in the spool directory

$base="/srv/email";
$base_maildir="$base";
$spool_dir = "$base/_spool";

$db_host = 'localhost';
$db_port = '3306';
$db_name = 'spammenot';
$db_user = '';
$db_pass = '';

$msglog="/var/log/spammenot/cron_$$.log"; ## your debug msg file location
#	open(MSG_TXT,">>$msglog");
#	select MSG_TXT; $|=1;					# make unbuffered


 #======================= [ open_dbi ] =======================
 # Connect to the requested server, otherwise dont start the daemon(s)
 # http://perl.about.com/library/weekly/aa090803a.htm

 $dbh = DBI->connect("DBI:mysql:$db_name:$db_host","$db_user","$db_pass",{'RaiseError' => 1});
 #======================= [ open_dbi ] =======================


	unless (-d $spool_dir and opendir DIR, $spool_dir ){
		&msg_txt("-01> $spool_dir does not appear to be a valid directory");
		#&log("$spool_dir does not appear to be a readable directory");
		die "$spool_dir does not appear to be a readable directory";
	}

	&msg_txt("-02>Spool Dir OK: $spool_dir");
	close DIR;


#--------------------------------------
# Program is in here!
&go_get_new;
close MSG_TXT;
exit;
#---------------------------------------

sub go_get_new {
	my ($to,$from,$subject,$err,@mx,$mx_is,$line);

	unless (-d $spool_dir and opendir DIR, $spool_dir ){
		&msg_txt("-03> $spool_dir does not appear to be a valid directory");
		#&log("$spool_dir does not appear to be a readable directory");
		die "$spool_dir does not appear to be a readable directory";
	}
	
	&msg_txt("-04> Looking for new msgs");
	
	# ignore messages that start with a plus sign
	# @messages = grep {!/^\+/} (grep {-f $_} (readdir DIR));

	# Need to make a new regecp that excludes ^+ OR .extra$
	
	@messages = grep {!/^\+/} (readdir DIR);
	$err = shift(@messages);		## throw out the . in directory listing
	$err = shift(@messages);		## throw out the .. in directory listing
	$err = "";
	
	&msg_txt("-05> I found ".scalar(@messages)." messages");
	if (!@messages) {
		# no new files to send
		&msg_txt("-05a> no messages? let us quit");
		return;
	}

	foreach $filename (@messages) {
		# NOTE: disk or other log file will contain all previous MSG_TXT entires unless we clear it, which we ain't
		my $mx_is, $file_extra;
		# $filename is a single filename returned from the list
		&msg_txt("-11> evaluating file: $filename");
		#print "\n -11> file: $filename\n";

		# Open the file	
		my $filepath="$spool_dir/$filename";

		open (LETTER,"<$filepath") or sub {
			&msg_txt("-12> cannot open $filepath");
			next ;
			};

		# grep out from the email a few things...
		# to, from.
		# if the domain is NOT local then mx the 'to' domain
		# Um, when would the domain BE local? I thought this prog always sent mail out
		#$to = "jfields\@toide.com";
		#$from = "jfields.extra\@piglet.fieldsfamily.net";

		my $tmp=1;
		$to=""; 
		$from="";
		$subject="";
		$session_log="Loading file from disk: $filepath";

		while (defined($line = <LETTER>)) {

			&msg_txt("-13> evaluating line: $line");
			
			if ($line=~/^X-Original-To: <([0-9a-zA-Z\.\-\_\:\@\#]+)>/io){
				$to = $1;
				&msg_txt("Found X-Recipient: <$to>");
				}
			if ($line=~/^to:[\w\W]*<([0-9a-zA-Z\.\-\_\:\@\#]+)>/io){
				$to2 = $1;
				&msg_txt("Found fallback TO: <$to2>");
				}
			if ($line=~/^from[\w\W]*<([0-9a-zA-Z\.\-\_\:\@\#]+)>/io) {
				$from = $1;
				&msg_txt("Found FROM: <$from>");
				}
			if ($line=~/^subject: ([\w\W]*)/io) {
				$subject = $1;		# nab this in case it bounces
				chomp $subject;		# strip any trailing CR/LF
				&msg_txt("Found SUBJECT: <$subject>");
				}
			
			if (((($to) || ($to2)) && ($from) && ($subject)) || ($tmp>99)) {
				# if both addresses are found, or if 100 lines have gone by.
				# all the headers SHOULD fit within the 100 line limit
				last;
			}
			$tmp +=1;

		} #end while LETTER
		&msg_txt("-LB> Outside of the while loop");

		# TMP patch added by JF Jan24,04
		# remove when mime_pummel_file is completed
		if ($to eq "") {
			# no $to means no found X-Orignal-To header found.  Look for my
			# special other file containing this info!
			$file_extra="$spool_dir/\+$filename.extra";
			if (!open (HEADER2,"<$file_extra")){
				&msg_txt("-14> cannot open $file_extra");
				next ;
			}else{
				&msg_txt("-15> Opened: $file_extra");
			}

			while (defined($line = <HEADER2>)) {
				&msg_txt("-16> evaluating line: $line");
				$extrafile = "Yes";			#So we can delete later.			
				if ($line=~/^X-Original-To: <([0-9a-zA-Z\.\-\_\:\@\#]+)>/io){
					$to = $1;
					&msg_txt("Found X-Recipient: <$to> in .extra file");
					}
			} #end while

			# WAAAAYYY TMP fix added by JF Jan20,04
			# remove when mime_pummel_file is completed
			if ($to eq "") {
				$to=$to2;	# use the email found in the TO fields (may not be correct!)
				}
			close HEADER2;
		}else{
			&msg_txt("-LA> Weird <$to> is NOT eq to ");
		} #end outer if!to

		&msg_txt("-LC> Just before if statement");

		if (!($to && $from)) {
			# BOUNCE this puppy!
			&msg_txt("Um, couldn't find a delivery pair! to:<$to> from:<$from>");
			close LETTER;
			my $file2="$spool_dir/\+$filename";
			&msg_txt("   Copying $filepath -->> $file2");
			copy ($filepath, $file2);

			if (!(unlink $filepath)) {
				&msg_txt("Could not delete: $filepath");
				#print "cannot delete file: $filepath\n";
				$sender->{log2sql}="SMTP";				## Force this error to be logged
			}else{
				&msg_txt("   Deleted: $filepath");
				}

			&msg_txt("   Skipping to next file/SMTP message");
			next;
		}


		# lookup the name of OUR mailserver so we can announce ourselves properly :)
		if (!($I_AM = lookup_my_mx_name($from))) {
			$I_AM = "mail.spammenot.com";
		}

		@mx=ValidEmailAddr($to);
		$mx_count = scalar(@mx);
		&msg_txt("-06> I found $mx_count mail servers");

		#  if (not_one_of_our_addresses) 
		## This code should send it along to another server nicely 
		## http://search.cpan.org/~gbarr/libnet-1.17/Net/SMTP.pm

		if ($mx_count==0) {
			# Maybe this server has no MX record?  Just direct to server?
			$to=~/^[0-9a-zA-Z\.\-\_\#]+\@([0-9a-zA-Z\.\-]+)$/;
			my $mx_is = $1;
			if ($smtp = Net::SMTP->new($mx_is,
	                           Hello => $I_AM, 
	                           Timeout => 30,
	                           Debug   => 0,
	                          )) {
				&msg_txt("New SMTP object created");
				$err = "";	# if one of the first attempts failed, $err would still be set!
			}else{
				&msg_txt("New SMTP object failed to be created! ($mx_is/$I_AM)");
				$err = "New SMTP object failed to be created! ($mx_is/$I_AM)";
			} #end of SMTP new object

		}else{
			# $mx_count is positive number! yea!
			foreach $rr (@mx) {
				$mx_is = $rr->exchange;
				&msg_txt("-07> MX to try is $mx_is");
	
				if ($smtp = Net::SMTP->new($mx_is,
		                           Hello => $I_AM,
		                           Timeout => 30,
		                           Debug   => 0,
		                          )) {
					&msg_txt("-08> SMTP server responded at $mx_is");
					$err = "";	# if one of the first attempts failed, $err would still be set!
	
		            last;
				}else{
					&msg_txt("-09> New SMTP object failed to be created! ($mx_is/$I_AM)");
					$err = "New SMTP object failed to be created! ($mx_is/$I_AM)";
				} #end of SMTP new object
	
			} #end of foreach

		} #end id mx_count

		if($smtp){
			    if ($smtp->mail($from)){
			    	&msg_txt("From: $from accepted");
			    	if ($smtp->to($to)) {
			    		&msg_txt("To: $to accepted");
						if ($smtp->data()) {
							&msg_txt(" DATA command accepted");
							seek LETTER, SEEK_SET, 0;	#reset the file pointer to zero bytes
	
							while (<LETTER>) {
								#&msg_txt("-15> send: $_");
								if (!($smtp->datasend($_))) {$err="server stopped accepting DATA!"; last;}
							}
	
						}else{
							$err = "Server did not accept the DATA command";
						} #end of DATA
					}else{
						$err = "Server did not accept recipient ($to)";
					} #end of RCPT to
				}else{
					$err = "Server did not accept MAIL from ($from)";
				} #end of MAIL from

			$smtp->dataend();
			$smtp->quit;

			close LETTER;

			if ($err) {
				&msg_txt("ERROR: $err");
				}

			if (!(unlink $filepath)) {
				&msg_txt("Could not delete: $filepath");
				#print "cannot delete file: $filepath\n";
				$sender->{log2sql}="SMTP";				## Force this error to be logged
			}else{
				&msg_txt("Deleted: $filepath");
				}

			if (defined($extrafile)){
				if (!(unlink $file_extra)) {
					&msg_txt("Could not delete: $file_extra");
					$sender->{log2sql}="SMTP";				## Force this error to be logged
				}else{
					&msg_txt("   Deleted: $file_extra");
					$file_extra = "";
					undef($extrafile);
					}
			} #end of extrafile

		} else {
			# BOUNCE this puppy!  $err should already be set.
			# $err = "Mail bounced to $to";
			&msg_txt("There was no smtp object");
		} #end of if($smtp)

		if ($err) {
			&msg_txt("-41> Acting on error: $err");
			local_bounce($to,$from,$subject,$I_AM,$err);
			$sender->{log2disk} = "SMTP";			# Make it log to disk
		}
		
		&log_session;		## Dump session to the log_session table, or disk, if so set.

	} #end of foreach

	#close DIR;

} #end of sub go_get_new




#>----------------------------------------------------------------------------
sub retry_undeliverable {
	# Look for files with a plus in front of them.
	# Um, not sure if we need this since we bounce immediate anyway


} #end of retry_undeliverables


#>----------------------------------------------------------------------------
sub local_bounce {
	my ($to,$from,$subject,$I_AM,$err)=@_;
	my $body,$sender,$tempname;

	# 1) load text from database
	# 2) search/replace for three pieces of info
	# 3) insert into local mail directory

	my $sth = $dbh->prepare("SELECT BODY 
				 FROM text_automated 
				 where TITLE=?") 
				 or die &log(1,"Couldn't prepare SQL err: $dbh->errstr");

	$sth->execute('BOUNCE-1') or die "Couldn't execute SQL err: " . $dbh->errstr;

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
	$dated = gmtime()." GMT0";
	
	# 2) search/replace for each piece of info
	$body=~s/\[date\]/$dated/iosg;		# Replace [date] with, um, now
	$body=~s/\[sender\]/$from/iosg;		# Replace [recip] with the actual email address
	$body=~s/\[recip\]/$to/iosg;		# Replace [recip] with the actual email address
	$body=~s/\[subject\]/$subject/iosg;	# Replace [subject] with the actual subject
	$body=~s/\[reason\]/$err/iosg;		# Replace [reason] with the error string
	#print "$body\n";

	
	# 3) insert into local mail directory
	$sender	= lookup4auth($from,$dbh);

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

	return ;
} #end of local_bounce


#>----------------------------------------------------------------------------
sub	lookup4auth{
	my ($address,$dbh) = @_;
	my $tmp	= {} ;			# define tmp as	an array

	if (length($address)<8) {
		&msg_txt("-12> user account must be at least 8 characters! <$address>");
		#print "-12> user account must be at least 8 characters! <$address>\n";
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
		$tmp->{fqaddress}	= $address;
		$tmp->{pw}			= $ref->{'PASSW'};
		$tmp->{status}		= $ref->{'STATUS'};	
		$tmp->{base}		= $ref->{'ADDRESS'};
		$tmp->{domain}		= $ref->{'DOMAIN'};
		$tmp->{account_id}	= $ref->{'ACCOUNT_ID'};
		$tmp->{cust_id}		= $ref->{'CUST_ID'};
		$tmp->{rules}		= $ref->{'RULES'};
		$tmp->{debug}		= $ref->{'DEBUG'};
		$tmp->{log2sql}		= $ref->{'LOG2SQL'};
		$tmp->{log2disk}	= $ref->{'LOG2DISK'};
		&msg_txt("-43> Found a row: addy=$tmp->{fqaddress} pw=$tmp->{pw} stat=$tmp->{status}  cust_id=$tmp->(cust_id)  max_recip=$tmp->{max_recipients} dbg=$sender->{debug} rules=$tmp->{rules}");
		#print "-13> Found a row: addy=$tmp->{fqaddress} pw=$tmp->{pw} stat=$tmp->{status}	max_recip=$tmp->{max_recipients} dbg=$sender->{debug} rules=$tmp->{rules}\n";
	}else{
		#if ($sth->rows == 0) {
		&msg_txt("-44> No base accounts matched $address");	
		#print "-14> No base accounts matched $address\n";	
	}

	$sth->finish();

   if ($tmp->{status} ne 'OK'){$tmp->{pw}="rejected";}
   
   return $tmp;

} #end of lookup4auth

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
	} #end of while
	
	# We successfully made all the dirs.
	return 1;
} #end of make_directories


#>----------------------------------------------------------------------------
sub ValidEmailAddr { #check if e-mail address format is valid
  my ($mail) = @_;													#in from name@host
  my $sender_domain,$rr;
	&msg_txt("-38>Inside Validate email: $mail");

  return 0 if ( $mail !~ /^[0-9a-zA-Z\.\-\_\#]+\@([0-9a-zA-Z\.\-]+)$/ ); #characters allowed on name: 0-9a-Z-._ on host: 0-9a-Z-. on between: @
  my $sender_domain = $1;
  return 0 if ( $mail =~ /^[^0-9a-zA-Z]|[^0-9a-zA-Z]$/);             #must start or end with alpha or num
  return 0 if ( $mail !~ /([0-9a-zA-Z]{1})\@./ );                    #name must end with alpha or num
  return 0 if ( $mail !~ /.\@([0-9a-zA-Z]{1})/ );                    #host must start with alpha or num
  return 0 if ( $mail =~ /.\.\-.|.\-\..|.\.\..|.\-\-./g );           #pair .- or -. or -- or .. not allowed
  return 0 if ( $mail =~ /.\.\_.|.\-\_.|.\_\..|.\_\-.|.\_\_./g );    #pair ._ or -_ or _. or _- or __ not allowed
  return 0 if ( $mail !~ /\.([a-zA-Z]{2,3})$/ );                     #host must end with '.' plus 2 or 3 alpha for TopLevelDomain (MUST be modified in future!)

  my $res  = Net::DNS::Resolver->new;
  my @mx   = mx($res, $sender_domain);
  if (@mx) {
	foreach $rr (@mx) {
		my $mxes = $rr->exchange;
		my $pref = $rr->preference;
		&msg_txt("   MX for $sender_domain is ($pref) $mxes");
		} #end of foreach
  } #end if MX

	$mx_count=scalar(@mx);
	if ($mx_count==0) {
		# OK, no MX records.  So.....
		# we could test if it has a SMTP server?
		#@mx = push($sender_domain);

		&msg_txt("-38I>leaving Validate email - OK but no MX for $sender_domain");
  		return;
	}else{
		&msg_txt("-38I>leaving Validate email - thumbs up to $mail");
		return @mx;
	}

} #End of ValidEmailAddr

#>----------------------------------------------------------------------------
sub lookup_my_mx_name {
	my ($from) = @_;
	my $domain;
   	&msg_txt("Checking for my mx name for <$from>");

	#characters allowed on name: 0-9a-Z-._ on host: 0-9a-Z-. on between: @
	if ($from=~/\@([0-9a-zA-Z\.\-]+)/) {
		$domain = $1;
	}else {
		return 0;
	}
	
	my $sth = $dbh->prepare("SELECT MX_SERVER 
				 FROM domains 
				 where FQDN=?") 
				 or die &log(1,"Couldn't prepare SQL err: $dbh->errstr");

	$sth->execute($domain) or die "Couldn't execute SQL err: " . $dbh->errstr;

	if (my $ref = $sth->fetchrow_hashref()) {
		$domain = $ref->{'MX_SERVER'};
		&msg_txt("Found domain mail server as $domain");
		}

	if ($sth->rows == 0) {
    	&msg_txt("No domain record found for <$domain>");
        }

	$sth->finish();
	
	return $domain;

} #End of lookup_my_mx_name

#>----------------------------------------------------------------------------

sub	msg_txt	{
	#print "@_\n";
	my $temp = shift(@_);

	# Save all loggable	stuff to a variable, so	it can be optionally output	
	$session_log .=	"$temp\r\n";

	print MSG_TXT "$temp\n";

} #end of msg_txt

#>----------------------------------------------------------------------------
sub log_session {

	&msg_txt("-90> log2SQL? $sender->{log2sql}");

	# get the CUST_ID field....
	$sender	= lookup4auth($from,$dbh);

	$time=localtime;
	print MSG_TXT "$time $$ @p\n";

	if ($sender->{log2disk}=~/(SMTP|ALL)/) {
		open(MSG_TXT,">>$msglog");
		select MSG_TXT; $|=1;					# make unbuffered
		print MSG_TXT "$session_log\r\n";
		print MSG_TXT "-----DISK LOGGING ENDS HERE-----\r\n";
		close MSG_TXT
	}

	if ($sender->{log2sql}!~/(SMTP|ALL)/) {
		return;
	}

	my @t = localtime;
#	my $ss=$t[0];
#	my $mm=$t[1];
#	my $hh=$t[2];
#	my $dd=$t[3];
#	my $MM=$t[4];
#	my $YYYY=$t[5];
	$t[4]=$t[4]+1;
	$t[5]=$t[5]+1900;
	$time_is = $t[5].$t[4].$t[3].$t[2].$t[1].$t[0];
	&msg_txt("-98> DBG=$sender->{debug}/$sender->{log2sql} Inserting session into MySQL log_session, Exiting");

	##http://www.perl.com/pub/a/1999/10/DBI.html

	my $sth = $dbh->prepare("INSERT INTO log_sessions 
							 (CUST_ID,_TIMESTAMP,SERVICE,TRANSCRIPT) values(?,?,?,?)") 
	or die &log(1,"Couldn't prepare SQL err: $dbh->errstr");

	$sth->execute($sender->{cust_id},$time_is,'POP3',$session_log) or die "Cannot execute SQL INSERT";
	$sth->finish();


} #end log_session

__END__	
                                                

/*
SQLyog Enterprise - MySQL GUI v6.07
Host - 5.0.45 : Database - spammenot
*********************************************************************
Server version : 5.0.45
*/

/*!40101 SET NAMES utf8 */;

/*!40101 SET SQL_MODE=''*/;

create database if not exists `spammenot`;

USE `spammenot`;

/*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;
/*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO' */;

/*Table structure for table `TPoL` */

DROP TABLE IF EXISTS `TPoL`;

CREATE TABLE `TPoL` (
  `_UNIQ` bigint(20) unsigned NOT NULL auto_increment,
  `ACCOUNT_ID` bigint(20) NOT NULL default '0',
  `USER_ID` bigint(20) NOT NULL default '0',
  `OUR_ADDRESS` varchar(129) NOT NULL default '',
  `THEIR_ADDRESS` varchar(129) NOT NULL default '',
  `OUR_PLUSSED` varchar(63) NOT NULL default '',
  `RULE` varchar(255) NOT NULL default '',
  `COUNT_RCV` bigint(1) unsigned NOT NULL default '0',
  `COUNT_SENT` bigint(1) unsigned NOT NULL default '0',
  `TRUSTED` enum('YES','PRIVATE','REJECT') NOT NULL default 'YES',
  `CR_COUNT` tinyint(10) unsigned NOT NULL default '0',
  `field9` char(2) NOT NULL default '',
  `field10` char(2) NOT NULL default '',
  UNIQUE KEY `_UNIQ` (`_UNIQ`),
  KEY `ADDRESS` (`OUR_ADDRESS`,`THEIR_ADDRESS`),
  KEY `ACCOUNT_ID` (`ACCOUNT_ID`),
  KEY `USER_ID` (`USER_ID`),
  KEY `OUR_PLUSSED` (`OUR_PLUSSED`)
) ENGINE=MyISAM AUTO_INCREMENT=2 DEFAULT CHARSET=latin1 COMMENT='Thousand Points of Light white & black list + counters';

/*Table structure for table `accounts` */

DROP TABLE IF EXISTS `accounts`;

CREATE TABLE `accounts` (
  `ACCOUNT_ID` bigint(20) unsigned NOT NULL auto_increment,
  `CUST_ID` bigint(20) unsigned NOT NULL default '0',
  `STATUS` varchar(10) NOT NULL default 'OK',
  `FIR_NAME` varchar(25) NOT NULL default '',
  `LAS_NAME` varchar(25) NOT NULL default '',
  `FQ_ADDRESS` varchar(128) NOT NULL default '',
  `ADDRESS` varchar(63) NOT NULL default '',
  `DOMAIN` varchar(63) NOT NULL default '',
  `PASSW` varchar(63) NOT NULL default '',
  `MAX_RECIP` tinyint(3) unsigned NOT NULL default '200',
  `RULES` varchar(255) NOT NULL default '',
  `DEBUG` tinyint(3) unsigned NOT NULL default '0',
  `LOG2SQL` enum('NO','SMTP','POP3','ALL') NOT NULL default 'NO',
  `LOG2DISK` enum('NO','SMTP','POP3','ALL') NOT NULL default 'NO',
  PRIMARY KEY  (`ACCOUNT_ID`),
  UNIQUE KEY `FQ_ADDRESS` (`FQ_ADDRESS`),
  KEY `ADDRESS` (`ADDRESS`),
  KEY `DOMAIN` (`DOMAIN`)
) ENGINE=MyISAM AUTO_INCREMENT=23 DEFAULT CHARSET=latin1 COMMENT='Base email addresses go here';

/*Table structure for table `customers` */

DROP TABLE IF EXISTS `customers`;

CREATE TABLE `customers` (
  `CUST_ID` bigint(20) unsigned NOT NULL auto_increment,
  `FIR_NAME` varchar(35) NOT NULL default '',
  `LAS_NAME` varchar(35) NOT NULL default '',
  `SERVICE_EXPIRES` datetime NOT NULL default '0000-00-00 00:00:00',
  `MAILING1` varchar(35) NOT NULL default '',
  `MAILING2` varchar(35) NOT NULL default '',
  `CITY` varchar(35) NOT NULL default '',
  `STATE` char(2) NOT NULL default '',
  `ZIP` varchar(10) NOT NULL default '',
  PRIMARY KEY  (`CUST_ID`),
  KEY `SERVICE_EXPIRES` (`SERVICE_EXPIRES`)
) ENGINE=MyISAM AUTO_INCREMENT=11 DEFAULT CHARSET=latin1 COMMENT='Customers name/addy go in here';

/*Table structure for table `domains` */

DROP TABLE IF EXISTS `domains`;

CREATE TABLE `domains` (
  `_UNIQ` int(11) NOT NULL auto_increment,
  `FQDN` varchar(64) NOT NULL default '',
  `MX_SERVER` varchar(64) NOT NULL default '',
  `STATUS` varchar(10) NOT NULL default 'OK',
  `CUST_ID` bigint(20) unsigned NOT NULL default '0',
  `CATCH_ALL` varchar(127) NOT NULL default '',
  `BUGSCREEN` bigint(20) unsigned NOT NULL default '0',
  `ADDED` datetime NOT NULL default '0000-00-00 00:00:00',
  UNIQUE KEY `_UNIQ` (`_UNIQ`),
  KEY `FQDN` (`FQDN`)
) ENGINE=MyISAM AUTO_INCREMENT=12 DEFAULT CHARSET=latin1 COMMENT='List of domains we serve';

/*Table structure for table `log_headers` */

DROP TABLE IF EXISTS `log_headers`;

CREATE TABLE `log_headers` (
  `_UNIQ` bigint(20) unsigned NOT NULL auto_increment,
  `XMAILER` varchar(100) NOT NULL default '',
  `XHEADER` varchar(30) NOT NULL default '',
  `VALUE` varchar(255) NOT NULL default '',
  `COUNTED` int(10) unsigned NOT NULL default '1',
  PRIMARY KEY  (`_UNIQ`),
  KEY `XHEADER` (`XHEADER`),
  KEY `VALUE` (`VALUE`),
  KEY `XMAILER` (`XMAILER`)
) ENGINE=MyISAM AUTO_INCREMENT=134179 DEFAULT CHARSET=latin1 PACK_KEYS=1 COMMENT='USe to study the plethora of custom X-??? headers';

/*Table structure for table `log_sessions` */

DROP TABLE IF EXISTS `log_sessions`;

CREATE TABLE `log_sessions` (
  `_UNIQ` bigint(20) unsigned NOT NULL auto_increment,
  `CUST_ID` int(10) unsigned NOT NULL default '0',
  `_TIMESTAMP` timestamp NOT NULL default CURRENT_TIMESTAMP on update CURRENT_TIMESTAMP,
  `SERVICE` enum('SMTP','POP3') NOT NULL default 'SMTP',
  `TRANSCRIPT` longtext NOT NULL,
  PRIMARY KEY  (`_UNIQ`),
  KEY `ACCOUNT_ID` (`CUST_ID`,`_TIMESTAMP`)
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COMMENT='This holds records created when the account debug flag is se';

/*Table structure for table `text_automated` */

DROP TABLE IF EXISTS `text_automated`;

CREATE TABLE `text_automated` (
  `_UNIQ` int(10) unsigned NOT NULL default '0',
  `TITLE` varchar(40) NOT NULL default '',
  `BODY` text NOT NULL,
  PRIMARY KEY  (`_UNIQ`),
  KEY `TITLE` (`TITLE`)
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COMMENT='Use to store Bounce msgs, auto-replies, etc. ';

/*!40101 SET SQL_MODE=@OLD_SQL_MODE */;
/*!40014 SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS */;

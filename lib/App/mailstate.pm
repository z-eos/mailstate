#!/usr/local/bin/perl
# -*- mode: cperl; eval: (follow-mode 1); cperl-indent-level: 2; cperl-continued-statement-offset: 2 -*-
#

package App::mailstate;

use strict;
use warnings;
use diagnostics;

use DBI;
use Data::Printer caller_info => 1, colored => 1, print_escapes => 1, output => 'stdout', class => { expand => 2 },
  caller_message => "DEBUG __FILENAME__:__LINE__ ";
use File::Basename;
use File::stat;
use Getopt::Long  qw(:config no_ignore_case gnu_getopt auto_help auto_version);
use Net::LDAP;
use Parse::Syslog::Mail;
use Pod::Man;
use Pod::Usage qw(pod2usage);;
use Sys::Syslog qw(:standard :extended :macros);
use Time::Piece;

my  @PROGARG = ($0, @ARGV);
our $VERSION = '0.0.1';

sub new {
  my $class = shift;
  my $self =
    bless {
	   _progname => fileparse($0),
	   _progargs => [$0, @ARGV],
	   _option   => { d                 => 0,
			  colored           => 0,
			  log => {
				  logfile => '/var/log/maillog',
				  save_to => './',
				 },
			  relay_domains_sfx => [ 'root','xx','ibs','ibs.dn.ua' ],
			  v                 => 0,
			  dryrun            => 0,
			  count             => 1,
			  export            => 'raw',
			},
	  }, $class;

  GetOptions(
             'l|logfile=s' => \$self->{_option}{log}{logfile},
             's|save-to=s' => \$self->{_option}{log}{save_to},
	     'v+'          => \$self->{_option}{v},
	     'c'           => \$self->{_option}{count},
	     'e|export=s'  => \$self->{_option}{export},
	     'n|dry-run'   => \$self->{_option}{dryrun},

	     'h|help'              => sub { pod2usage(-exitval => 0, -verbose => 2); exit 0 },
	     'd|debug+'            => \$self->{_option}{d},
	     'V|version'           => sub { print "$self->{_progname}, version $VERSION\n"; exit 0 },
	    );

  if ( $self->{_option}{export} && 
       $self->{_option}{export} ne 'sqlite' &&
       $self->{_option}{export} ne 'raw' ) {
    $self->debug_msg( {priority => 'err',
		message   => "error: Wrong export format. Allowed formats are sqlite and raw",
		verbosity => $self->{_option}{v} });
    exit 1;
  }

  print "log file to be used is: $self->{_option}{log}{logfile}\n" if $self->{_option}{v} > 0;

  if ( ! -f $self->{_option}{log}{logfile} ) {
    $self->debug_msg({ priority => 'err',
		message   => "error: log file configured is $self->{_option}{log}{logfile}; %m",
		verbosity => $self->{_option}{v} });
    # pod2usage(0);
    exit 1;
  } elsif ( ! $self->{_option}{export} ) {
    $self->debug_msg({ priority => 'warning',
		message   => "warning: no extension given, set it please",
		verbosity => $self->{_option}{v} });
    # pod2usage(0);
    exit 1;
  } elsif ( defined $self->{log}->{save_to} && ! -d $self->{log}->{save_to} ) {
    $self->debug_msg( {priority => 'warning',
		message   => "warning: directory to save db file to is $self->{log}->{save_to}; %m",
		verbosity => $self->{_option}{v} });
    # pod2usage(0);
    exit 1;
  }

  return $self;
}

sub progname { shift->{_progname} }
sub progargs { return join(' ', @{shift->{_progargs}}); }

sub o {
  my ($self,$opt) = @_;
  return $self->{_option}{$opt};
}

sub l { shift->{_option}{log} }

sub v { shift->{_option}{v} }

sub run {
  my $self = shift;

  my $element;
  my $i;
  my $id;
  my $index;
  my $key;
  my $log;
  my $res;
  my $rest;
  my $t;
  my $ts;
  my $val;
  my @log_row;

  ( $self->l->{name}, $self->l->{dirs}, $self->l->{suffix} ) = fileparse($self->o('log')->{logfile});
  $self->l->{stat} = stat($self->o('log')->{logfile});

  my $maillog = Parse::Syslog::Mail->new( $self->o('log')->{logfile},
					  allow_future => 1);
  while ( my $r = $maillog->next ) {
    next if $r->{text} =~ /AUTH|STARTTLS|--|NOQUEUE/;

    if ( exists $r->{'to'} ) {

      $res->{$r->{id}}->{timestamp}->{to} = $r->{timestamp}         // 'NA';
      $res->{$r->{id}}->{delay}           = $r->{delay}             // 'NA';
      $res->{$r->{id}}->{xdelay}          = $r->{xdelay}            // 'NA';
      $res->{$r->{id}}->{dsn}             = $r->{dsn}               // 'NA';
      $res->{$r->{id}}->{status}          = $r->{status}            // 'NA';
      $res->{$r->{id}}->{addr}->{to}      = $self->strip_addr($r->{to})
	if exists $r->{to};
      $res->{$r->{id}}->{relay}->{to}     = $self->split_relay($r->{relay})
	if exists $r->{relay};

    } elsif ( exists $r->{'from'} ) {

      $res->{$r->{id}}->{timestamp}->{fr} = $r->{timestamp}         // 'NA';
      $res->{$r->{id}}->{size}            = $r->{size};
      $res->{$r->{id}}->{addr}->{fr}      = $self->strip_addr($r->{from})
	if exists $r->{from};
      $res->{$r->{id}}->{msgid}           = $self->strip_addr($r->{msgid})
	if exists $r->{msgid};
      $res->{$r->{id}}->{relay}->{fr}     = $self->split_relay($r->{relay})
	if exists $r->{relay};
    }

    $res->{$r->{id}}->{connection} = $r->{status}
      if exists $r->{status} &&
      $r->{status} =~ /^.*connection.*$/ &&
      $r->{status} !~ /^.*did not issue.*$/;
  }

  p $res if $self->o('export') eq 'raw' || $self->v > 2;

  $self->tosqlite( { log_rows  => $res, } )
    if $self->o('export') eq 'sqlite' && ! $self->o('dryrun');

  exit 0;
}

######################################################################
#
######################################################################

sub debug_msg {
  my ($self, $args) = @_;
  my $arg = { priority  => $args->{priority},
	      message   => $args->{message},
	      verbosity => $args->{verbosity} || 0, };

  openlog($self->{_progname}, "pid", LOG_MAIL);
  syslog($arg->{priority}, $arg->{message});
  closelog();
  print "DEBUG: $arg->{message}\n" if $arg->{verbosity} > 0
}

sub split_relay {
  my ($self, $relay) = @_;
  my $return;
  if ( $relay =~ /^([\w,\.]+) \[(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\].*$/ ) {
    $return->{fqdn} = $1;
    $return->{ip}   = $2;
  } elsif ($relay =~ /\[(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\].*$/) {
    $return->{fqdn} = 'NA';
    $return->{ip}   = $1;
  } elsif ($relay =~ /\[(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\] \[(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\].*$/) {
    $return->{fqdn} = $1;
    $return->{ip}   = $2;
  } else {
    $return->{fqdn} = $relay;
    $return->{ip}   = 'NA';
  }
  return $return;
}

sub strip_addr {
  my ($self, $addr) = @_;
  my $return;
  if ($addr =~ /<(.*@.*)>/) {
    $return = $1;
  } else {
    $return = $addr;
  }
  return lc($return);
}

sub tosqlite {
  my ($self, $args) = @_;

  $args->{logfilemtime} = localtime($self->l->{stat}->mtime);

  my $tl = localtime;
  my $arg =
    {
     log_rows  => $args->{log_rows},
     localtime => $self->{_tl},
     dbfile    =>
     sprintf('%s%s-%s-v%s%s.sqlite',
	     $self->l->{save_to} ne '' ? $self->l->{save_to} . '/' : $self->l->{dirs},
	     $self->l->{name},
	     $args->{logfilemtime}->ymd(''),
	     $tl->ymd(''),
	     $tl->hms(''),
	    ),
    };

  p $arg if $self->v > 3;
  print "database file to be used is: $arg->{dbfile}\n" if $self->v;

  my $dbh = DBI->connect("dbi:SQLite:dbname=$arg->{dbfile}","","",
			 { AutoCommit => 1,
			   RaiseError => 1, });

  $dbh->do("PRAGMA cache_size = 100000") or die $dbh->errstr;
  $dbh->begin_work or die $dbh->errstr;

  my $tbl_create = qq{CREATE TABLE maillog
  -- $self->l->{logfile} data processed, generated with mailstate
  -- results are written to $arg->{dbfile}
  (
    id              TEXT PRIMARY KEY, -- sendmail message ID (macros \$i)
    ts              TEXT,             -- timestamp
    addr_fr         TEXT,             -- MAIL From
    addr_to         TEXT,             -- RCPT To
    size            NUM,              -- message size
    delay           TEXT,             -- delay
    xdelay          TEXT,             -- delay
    relay_fr_ip     TEXT,             -- ip address of the sender relay
    relay_fr_fqdn   TEXT,             -- fqdn of the sender relay
    relay_to_ip     TEXT,             -- ip address of the recipient relay
    relay_to_fqdn   TEXT,             -- fqdn of the recipient relay
    dsn             TEXT,             -- DSN code
    msgid           TEXT,             -- Message-ID header
    stat            TEXT              -- Status
  );};
  p $tbl_create if $self->v > 1;
  $dbh->do($tbl_create) or die $dbh->errstr;

  my $idx_create = [ q{CREATE INDEX addr_fr ON maillog ( addr_fr );},
		     q{CREATE INDEX addr_to ON maillog ( addr_to );},
		     q{CREATE INDEX from_to_addr ON maillog ( addr_fr, addr_to );},
		     q{CREATE INDEX relay_fr_ip ON maillog ( relay_fr_ip );},
		     q{CREATE INDEX relay_fr_fqdn ON maillog ( relay_fr_fqdn );},
		     q{CREATE INDEX relay_to_ip ON maillog ( relay_to_ip );},
		     q{CREATE INDEX relay_to_fqdn ON maillog ( relay_to_fqdn );},
		     q{CREATE INDEX msgid ON maillog ( msgid );},
		     q{CREATE INDEX stat ON maillog ( stat );} ];

  foreach (@{$idx_create}) {
    p $_ if $self->v > 1;
    $dbh->do($_) or die $dbh->errstr;
  }

  my $sth;
  foreach ( keys ( %{$arg->{log_rows}} ) ) {
    next if ! $arg->{log_rows}->{$_}->{addr}->{to} ||
      ! $arg->{log_rows}->{$_}->{addr}->{fr};
    $sth = $dbh->prepare('INSERT INTO maillog VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)');
    $sth->execute( $_,
		   $arg->{log_rows}->{$_}->{timestamp}->{to},
		   $arg->{log_rows}->{$_}->{addr}->{fr},
		   $arg->{log_rows}->{$_}->{addr}->{to},
		   $arg->{log_rows}->{$_}->{size},
		   $arg->{log_rows}->{$_}->{delay},
		   $arg->{log_rows}->{$_}->{xdelay},
		   $arg->{log_rows}->{$_}->{relay}->{fr}->{ip},
		   $arg->{log_rows}->{$_}->{relay}->{fr}->{fqdn},
		   $arg->{log_rows}->{$_}->{relay}->{to}->{ip},
		   $arg->{log_rows}->{$_}->{relay}->{to}->{fqdn},
		   $arg->{log_rows}->{$_}->{dsn},
		   $arg->{log_rows}->{$_}->{msgid},
		   $arg->{log_rows}->{$_}->{status},
		 );
  }

  $dbh->commit or die $dbh->errstr;

  $dbh->begin_work or die $dbh->errstr;
  $tbl_create = qq{CREATE TABLE IF NOT EXISTS addr_to_unique
  -- $self->l->{logfile} data processed, generated with mailstate
  -- results are written to $arg->{dbfile}
  -- table contains all unique, not served by us, RCPT TO addresses 
  (
    addr_to_unique TEXT PRIMARY KEY, -- RCPT TO (not ours recipients)
    addr_to_count  NUM               -- emails sent to addr_to number
  );};
  p $tbl_create if $self->v > 1;
  $dbh->do($tbl_create) or die $dbh->errstr;

  $arg->{addr_to_unique_select} = sprintf("
INSERT INTO addr_to_unique (addr_to_unique, addr_to_count)
       SELECT DISTINCT lower(addr_to), count(addr_to)
              FROM maillog WHERE substr(addr_to,instr(addr_to, '\@') + 1) NOT IN ( '%s' )
              AND addr_to NOT LIKE '%%,%%' GROUP BY addr_to",
					  join("','", @{relay_domains()}, @{$self->o('relay_domains_sfx')}));

  p $arg->{addr_to_unique_select} if $self->v > 1;
  $dbh->do($arg->{addr_to_unique_select}) or die $dbh->errstr;
  #$sth = $dbh->prepare( $arg->{addr_to_unique_select} );
  #$sth->execute( "'" . join("','", @{relay_domains()}) . "','root'" );
  $dbh->commit or die $dbh->errstr;

  $dbh->disconnect;

  $self->debug_msg({ priority  => 'info',
	      message   => sprintf('info: processing complete %s%s -> %s',
				  $self->l->{dirs},
				  $self->l->{name},
				  $arg->{dbfile}),
	      verbosity => $self->v });
}

sub relay_domains {
  my ($self, $args) = @_;
  #   my $args = shift @_;
#   my $relay_domains;
#   my $ldap = Net::LDAP->new ( 'localhost', async => 1 ) or die "$@";
#   my $bind_msg = $ldap->bind ( version => 3 );
#   p $bind_msg->error if $bind_msg->code;
#   my $fqdns =
#     $ldap->search(base   => "sendmailMTAMapName=smarttable,ou=relay.xx,ou=Sendmail,dc=ibs",
# 		  scope  => "one",
# 		  filter => "sendmailMTAKey=*",
# 		  attrs  => [ 'sendmailMTAKey' ],
# 		 );
#   my @fqdn_arr = $fqdns->entries;
#   my $a;
#   foreach ( @fqdn_arr ) {
#     $a = $_->get_value('sendmailMTAKey', asref => 1);
#     # p $a;
#     push @{$relay_domains}, substr($a->[0],1);
#   }
#   return $relay_domains;
  return [];
}

1;

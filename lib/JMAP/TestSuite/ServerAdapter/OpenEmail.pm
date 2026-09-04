package JMAP::TestSuite::ServerAdapter::OpenEmail;
use Moose;
with 'JMAP::TestSuite::ServerAdapter';

# OpenEmail JMAP adapter for the JMAP-TestSuite.
#
# OpenEmail exposes JMAP at:
#   Session:  GET  /.well-known/jmap  (also /jmap/session)
#   API:      POST /jmap/api
#   Upload:   POST /jmap/upload/{accountId}
#   Download: GET  /jmap/download/{accountId}/{blobId}/{name}
#
# Auth: HTTP Basic (mailbox username + password) or Bearer (API key / app
# password). The adapter uses Basic because the test suite provisions plain
# passwords.
#
# In "local" mode, base_uri points at the local dev server (e.g.
# http://localhost:8787) and the provisioning script pre-creates the
# account. In "live" mode, base_uri points at a deployed worker and the
# caller supplies pre-existing credentials.
#
# PRISTINE ACCOUNTS. When the config carries `system_key`, `account_id` and
# `domain`, this adapter can mint a BRAND-NEW mailbox (with its own app
# password) on demand. That is what `pristine_account` is for, and it is
# load-bearing for two separate reasons:
#
#   1. Ten test files in the suite are skipped outright without it, because
#      they assert on the WHOLE account ("no existing entities", "sorting and
#      limiting" over every mailbox, and so on).
#   2. Every other test file shares one credential otherwise, and the JMAP
#      surface throttles PER CREDENTIAL (300/min). A serial `prove` run of the
#      full suite exhausts that budget partway through and every remaining
#      file dies on `urn:ietf:params:jmap:error:limit` — failures that look
#      like conformance bugs and are not. A fresh credential per test file
#      keeps each file inside its own budget.
#
# Without those config fields the adapter simply does not declare
# `pristine_account` (the suite tests `->can('pristine_account')`), so the
# old single-shared-account behaviour is preserved exactly.

use HTTP::Tiny;
use JSON::MaybeXS ();
use MIME::Base64 ();

has base_uri => (
  is       => 'ro',
  required => 1,
);

has credentials => (
  isa     => 'ArrayRef[HashRef]',
  traits  => ['Array'],
  handles => { credentials => 'elements' },
  required => 1,
);

# --- Optional provisioning configuration -----------------------------------
# All three must be present for pristine_account to be offered.

has system_key => (is => 'ro', predicate => 'has_system_key');
has account_id => (is => 'ro', predicate => 'has_account_id');
has domain     => (is => 'ro', predicate => 'has_domain');

has _json => (
  is      => 'ro',
  lazy    => 1,
  default => sub { JSON::MaybeXS->new->utf8->canonical },
);

has _http => (
  is      => 'ro',
  lazy    => 1,
  default => sub { HTTP::Tiny->new(timeout => 30) },
);

sub can_provision {
  my ($self) = @_;
  return $self->has_system_key && $self->has_account_id && $self->has_domain;
}

# The suite asks `->can('pristine_account')` to decide whether to run the ten
# whole-account tests.  `can` must therefore answer NO when this config carries
# no provisioning credentials, even though the method is compiled into the
# class unconditionally.
sub can {
  my ($self, $method, @rest) = @_;

  if ($method eq 'pristine_account' && ref $self && ! $self->can_provision) {
    return undef;
  }

  return $self->SUPER::can($method, @rest);
}

has _shared_account => (is => 'rw', predicate => '_has_shared_account');

# WHY any_account IS ALSO FRESH.  Upstream adapters hand every test file the
# one configured account.  Against OpenEmail that does not work: the JMAP
# surface throttles PER CREDENTIAL, so a serial run of the full suite spends
# one credential's whole budget partway through and every later file dies on
# `urn:ietf:params:jmap:error:limit`.  Each .t file is its own process, so
# memoising here means one fresh mailbox per FILE — enough isolation to keep
# each file inside its own budget, and cheap enough to be invisible.
#
# Without provisioning config this falls back to the configured account, which
# is the upstream behaviour exactly.
sub any_account {
  my ($self) = @_;

  unless ($self->can_provision) {
    my ($credentials) = $self->credentials;

    return JMAP::TestSuite::Account::OpenEmail->new({
      server      => $self,
      accountId   => $credentials->{accountId},
      credentials => $credentials,
    });
  }

  return $self->_shared_account if $self->_has_shared_account;

  my $account = $self->pristine_account;
  $self->_shared_account($account);

  return $account;
}

# --- Provisioning helpers ---------------------------------------------------

sub _api {
  my ($self, $method, $path, $body) = @_;

  my $base = $self->base_uri =~ s{/\z}{}r;
  my %opts = (
    headers => {
      'Authorization' => 'Bearer ' . $self->system_key,
      'Content-Type'  => 'application/json',
    },
  );
  $opts{content} = $self->_json->encode($body) if $body;

  my $res = $self->_http->request($method, "$base/api/v1$path", \%opts);

  unless ($res->{success}) {
    Carp::confess(
      "provisioning call $method $path failed: $res->{status} $res->{reason}: "
      . ($res->{content} // '')
    );
  }

  return length($res->{content} // '')
       ? $self->_json->decode($res->{content})
       : {};
}

{
  # A monotonically increasing suffix so two mailboxes minted inside the same
  # process never collide, plus the pid so two concurrent `prove` workers do
  # not either.
  my $seq = 0;

  sub _fresh_local_part {
    my ($self) = @_;
    $seq++;
    return sprintf 'jmt-%d-%d-%d', $$, time, $seq;
  }
}

sub pristine_account {
  my ($self) = @_;

  Carp::confess("pristine_account called without provisioning config")
    unless $self->can_provision;

  my $local   = $self->_fresh_local_part;
  my $address = $local . '@' . $self->domain;

  # Mailbox creation and credential minting live under `/identities`; the
  # read side (GET /mailboxes/{id}, messages, uploads, …) kept the old prefix.
  # Posting to `/mailboxes` 404s, which surfaces as every test file dying in
  # any_account rather than as anything resembling a conformance failure.
  my $mailbox = $self->_api(POST => '/identities', {
    accountId      => $self->account_id,
    primaryAddress => $address,
  });

  my $mailbox_id = $mailbox->{id}
    or Carp::confess("mailbox creation returned no id");

  # A route is what makes the address deliverable; the suite's Email/import
  # and EmailSubmission paths care.
  $self->_api(POST => '/routes', {
    address         => $address,
    destinationType => 'mailbox',
    mailboxId       => $mailbox_id,
  });

  my $cred = $self->_api(POST => "/identities/$mailbox_id/credentials", {
    kind => 'app_password',
  });

  return JMAP::TestSuite::Account::OpenEmail->new({
    server      => $self,
    accountId   => $mailbox_id,
    credentials => {
      username => $cred->{username},
      password => $cred->{token},
      accountId => $mailbox_id,
    },
  });
}

no Moose;
__PACKAGE__->meta->make_immutable;

# --------------------------------------------------------------------------
# Account implementation (same file, following the Cyrus/Simple pattern)
# --------------------------------------------------------------------------

package JMAP::TestSuite::Account::OpenEmail;
use Moose;
with 'JMAP::TestSuite::Account';

use MIME::Base64 ();

has credentials => (is => 'ro', required => 1);

sub authenticated_tester {
  my ($self) = @_;

  my $base = $self->server->base_uri =~ s{/\z}{}r;
  my $creds = $self->credentials;

  my $auth = join q{:}, @{$creds}{ qw(username password) };

  require JMAP::TestSuite::JMAP::Tester::WithSugar;

  # api_uri points at /jmap/api which serves both:
  #   GET  → the JMAP Session resource
  #   POST → method calls
  # default_arguments injects accountId into every method call so the
  # tests don't need to supply it explicitly.
  my $tester = JMAP::TestSuite::JMAP::Tester::WithSugar->new({
    api_uri      => "$base/jmap/api",
    upload_uri   => "$base/jmap/upload/{accountId}",
    download_uri => "$base/jmap/download/{accountId}/{blobId}/{name}",
    default_arguments => {
      accountId => $self->accountId,
    },
  });

  # AUTH SCHEME.  An OpenEmail app password (`oemp_…`) is a BEARER token: the
  # server resolves it with one hash lookup.  A plain login password is only
  # accepted over RFC 7617 Basic, and that door runs a 100k-iteration PBKDF2
  # behind a per-(username, source IP) guessing budget.  A conformance run mints
  # a fresh credential per test file, so every file would be a cache miss on
  # that budget and the run would throttle itself on `verifyip:` long before it
  # finished — failures that look like conformance bugs and are not.  Basic auth
  # has its own dedicated coverage in core (test/jmap/basic-auth.test.ts); this
  # suite is here for JMAP semantics.  So: Bearer when we hold a token, Basic
  # when all we have is a password.
  my $authorization = $creds->{password} =~ /\A(?:oemp_|oek_)/
    ? 'Bearer ' . $creds->{password}
    : 'Basic ' . MIME::Base64::encode_base64($auth, '');

  $tester->ua->set_default_header(Authorization => $authorization);

  return $tester;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;

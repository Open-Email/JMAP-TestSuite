use jmaptest;

# SKIPPED against openemail-core, which serves a FLAT Mailbox namespace and says
# so in the session capability: RFC 8621 §2 defines `maxMailboxDepth` as "one
# more than the maximum number of ancestors a Mailbox may have", and this server
# advertises 1 — i.e. no ancestors — together with `myRights.mayCreateChild:
# false`. A `Mailbox/set create` carrying `parentId` is therefore refused with
# `invalidProperties`, which is the specified way to decline it, and this file's
# FIXTURE cannot be built at all (every case here hangs off a parent/child pair).
#
# This is a deliberate architecture, recorded in docs/jmap-design.md §II.2: the
# store is Gmail-style LABELS, and synthesising hierarchy from slashes would
# invent phantom parents no label backs and diverge from the IMAP gateway's view
# of the same store.
#
# Skipped rather than DELETED (both these files were briefly deleted outright):
# a file removed from the oracle takes its coverage with it and leaves no record
# that a question was ever asked. A skip keeps the question, and the day this
# server grows nesting the skip is what says which tests to turn back on.
plan skip_all => "server advertises maxMailboxDepth: 1 (flat Mailbox namespace)";

# We need to know that only our mailboxes here exist for predicting filter
# results, so we need a pristine account.
attr pristine => 1;

test {
  my ($self) = @_;

  my $account = $self->pristine_account;
  my $tester  = $account->tester;

  my $mailbox1 = $account->create_mailbox({
    name => 'aaa',
  });

  my $mailbox2 = $account->create_mailbox({
    parentId => $mailbox1->id,
    name => 'bbb',
  });

  my $res = $tester->request({
    methodCalls => [[
      "Mailbox/get" => {},
    ]],
  });

  my @mailboxes = @{
    $res->single_sentence("Mailbox/get")->arguments->{list}
  };

  my @with_roles = grep {; $_->{role} } @mailboxes;

  plan skip_all => "No mailboxes with roles found, can't continue"
    unless @with_roles;

  my %mailboxes_by_id = map {; $_->{id} => $_ } @mailboxes;

  my $describer_sub = $self->make_describer_sub(\%mailboxes_by_id);

  my @all_name_asc = map {;
    $_->{id}
  } sort {
    $a->{name} cmp $b->{name}
  } @mailboxes;

  my @with_role_name_asc = map {;
    $_->{id}
  } sort {
    $a->{name} cmp $b->{name}
  } @with_roles;

  # AND
  $self->test_query(
    $account,
    "Mailbox/query",
    {
      filter => {
        operator => 'AND',
        conditions => [
          { hasAnyRole => JSON::false, },
          { parentId => undef, },
        ],
      },
      sort => [{ property => 'name', isAscending => JSON::true, }],
    },
    { ids => [ $mailbox1->id ], },
    $describer_sub,
    "AND - two conditions",
  );

  $self->test_query(
    $account,
    "Mailbox/query",
    {
      filter => {
        operator => 'AND',
        conditions => [
          { hasAnyRole => JSON::false, },
          { parentId => $mailbox1->id, },
        ],
      },
      sort => [{ property => 'name', isAscending => JSON::true, }],
    },
    { ids => [ $mailbox2->id ], },
    $describer_sub,
    "AND - two conditions",
  );

  $self->test_query(
    $account,
    "Mailbox/query",
    {
      filter => {
        operator => 'AND',
        conditions => [
          {
            operator => 'AND',
            conditions => [
              { hasAnyRole => JSON::false, },
              { parentId => $mailbox1->id, },
            ],
          },
        ],
      },
      sort => [{ property => 'name', isAscending => JSON::true, }],
    },
    { ids => [ $mailbox2->id ], },
    $describer_sub,
    "AND - two conditions nested one level deep",
  );

  # OR
  $self->test_query(
    $account,
    "Mailbox/query",
    {
      filter => {
        operator => 'OR',
        conditions => [
          { hasAnyRole => JSON::false, },
          { parentId => $mailbox1->id, },
        ],
      },
      sort => [{ property => 'name', isAscending => JSON::true, }],
    },
    { ids => [ $mailbox1->id, $mailbox2->id ], },
    $describer_sub,
    "OR - two conditions",
  );

  $self->test_query(
    $account,
    "Mailbox/query",
    {
      filter => {
        operator => 'OR',
        conditions => [
          { hasAnyRole => JSON::true, },
          { hasAnyRole => JSON::true, },
        ],
      },
      sort => [{ property => 'name', isAscending => JSON::true, }],
    },
    { ids => [ @with_role_name_asc ], },
    $describer_sub,
    "OR - two conditions, same cond",
  );

  $self->test_query(
    $account,
    "Mailbox/query",
    {
      filter => {
        operator => 'OR',
        conditions => [
          { hasAnyRole => JSON::true, },
          { hasAnyRole => JSON::false, },
        ],
      },
      sort => [{ property => 'name', isAscending => JSON::true, }],
    },
    { ids => [ @all_name_asc ], },
    $describer_sub,
    "OR - two conditions, diff conds",
  );

  # NOT
  $self->test_query(
    $account,
    "Mailbox/query",
    {
      filter => {
        operator => 'NOT',
        conditions => [
          { hasAnyRole => JSON::true, },
        ],
      },
      sort => [{ property => 'name', isAscending => JSON::true, }],
    },
    { ids => [ $mailbox1->id, $mailbox2->id ], },
    $describer_sub,
    "NOT - one condition",
  );

  $self->test_query(
    $account,
    "Mailbox/query",
    {
      filter => {
        operator => 'NOT',
        conditions => [
          { hasAnyRole => JSON::true, },
          { hasAnyRole => JSON::false, },
        ],
      },
      sort => [{ property => 'name', isAscending => JSON::true, }],
    },
    { ids => [ ], },
    $describer_sub,
    "NOT - two conditions",
  );
};

sub make_describer_sub {
  my ($self, $mailboxes_by_id) = @_;

  return sub {
    my ($self, $id) = @_;

    return    $mailboxes_by_id->{$id}->{name}
           || $mailboxes_by_id->{$id}->name;
  }
}

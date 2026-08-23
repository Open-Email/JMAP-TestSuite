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

test {
  my ($self) = @_;

  my $account = $self->any_account;
  my $tester  = $account->tester;

  my $mailbox1 = $account->create_mailbox;
  my $mailbox2 = $account->create_mailbox({
    parentId => $mailbox1->id,
  });

  subtest "has child" => sub {
    my $set_res = $tester->request([[
      "Mailbox/set" => {
        destroy => [ $mailbox1->id ],
        onDestroyRemoveMessages => JSON::true,
      },
    ]]);

    jcmp_deeply(
      $set_res->single_sentence('Mailbox/set')->arguments->{notDestroyed},
      {
        $mailbox1->id => {
          type => 'mailboxHasChild',
        },
      },
      'got mailboxHasChild error'
    );
  };

  subtest "no longer has child" => sub {
    $mailbox2->destroy;

    my $set_res = $tester->request([[
      "Mailbox/set" => {
        destroy => [ $mailbox1->id ],
        onDestroyRemoveMessages => JSON::true,
      },
    ]]);

    jcmp_deeply(
      $set_res->single_sentence('Mailbox/set')->arguments->{destroyed},
      [ $mailbox1->id ],
      'mailbox destroyed'
    );

    my $get_res = $tester->request([[
      "Mailbox/get" => { ids => [ $mailbox1->id ] },
    ]]);

    jcmp_deeply(
      $get_res->single_sentence('Mailbox/get')->arguments->{list},
      [],
      'no mailboxes returned'
    );

    jcmp_deeply(
      $get_res->single_sentence('Mailbox/get')->arguments->{notFound},
      [ $mailbox1->id ],
      'our destroyed mailbox not found'
    );
  };
};

use jmaptest;

# Can't have existing data so must be pristine
attr pristine => 1;

test {
  my ($self) = @_;

  my $account = $self->pristine_account;
  my $tester  = $account->tester;

  subtest "No arguments" => sub {
    my $res = $tester->request([[
      "Mailbox/get" => {},
    ]]);
    ok($res->is_success, "Mailbox/get")
      or diag explain $res->response_payload;

    my $args = $res->single_sentence("Mailbox/get")->arguments;

    jcmp_deeply(
      $args,
      superhashof({
        accountId => jstr($account->accountId),
        state     => jstr(),
        notFound  => [],
      }),
      "Mailbox/get response looks good",
    );

    # Filter out system role mailboxes (inbox, drafts, sent, trash, junk, archive)
    my @custom_mailboxes = grep { !defined $_->{role} } @{ $args->{list} };
    is(@custom_mailboxes, 0, "No custom mailboxes exist on pristine account");
  };
};

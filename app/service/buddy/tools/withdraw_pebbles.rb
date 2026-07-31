Buddy::Tools.register(
  name:        :withdraw_pebbles,
  description: <<~TXT,
    Take pebbles OUT of their chore balance - what they cashed in and what
    they spent it on. Use when they say they've spent some: "withdraw 50",
    "took 20 pebbles for the arcade", "cashed in 15 on a movie", "spent 30".

    Always pass `note` when they say what it went to ("for the arcade",
    "movie night", "new headphones"). The withdrawal list is the ONLY record
    of where their pebbles went, so a note-less withdrawal is a number with no
    story - if they mentioned what it was for, capture it.

    Don't confuse this with a chore's reward. "Add a chore for 2p" sets what a
    chore PAYS and belongs to create_chore / edit_chore; this SPENDS what
    they've already earned.
  TXT
  args:        {
    amount: { type: :integer, required: true,  description: "How many pebbles to take out. Must be positive." },
    note:   { type: :string,  required: false, description: "What they spent it on" },
  },
  confirm:     ->(payload, ctx) {
    amount = payload[:amount].to_i
    raise "a withdrawal has to be a positive number of pebbles" unless amount.positive?

    balance = ctx.user.chore_balance
    after   = balance - amount
    # The app lets a balance go negative and this deliberately doesn't get
    # stricter than the app. But an overdraw is far more often a misheard
    # number than an intended one, so the model is told outright rather than
    # left to discover it - and the row shows the person the same thing.
    overdrawn = after.negative? ? " This takes them NEGATIVE - say so." : ""

    {
      summary:  "Withdraw #{amount}p, leaving #{after}p of #{balance}p.#{overdrawn}",
      resolved: { balance_after: after },
    }
  },
  label:       ->(payload, _ctx) {
    subs = []
    subs << "📝 #{payload[:note]}" if payload[:note].present?
    subs << "leaves #{payload[:balance_after]}p" if payload[:balance_after]

    { title: "Withdraw #{payload[:amount]}p", sub: subs.join("\n").presence }
  },
  # Level 2: takes effect immediately as a pre-checked row, and unchecking it
  # destroys the withdrawal and puts the pebbles back. Matches complete_chore,
  # which credits the same balance - the two halves of the ledger shouldn't
  # need different amounts of ceremony.
  level:       2,
  execute:     ->(payload, ctx) {
    withdrawal = ctx.user.chore_withdrawals.create!(
      amount_pebbles: payload[:amount].to_i,
      note:           payload[:note].presence,
    )
    # Same two follow-ups the Balance page does on its own withdrawals: goal
    # cards read the balance, and the Chores app has no other way to know.
    ChoreGoal.refresh_all_for(ctx.user)
    ChoreBroadcaster.broadcast_changes!(ctx.user)

    {
      withdrawal_id: withdrawal.id,
      balance:       ctx.user.chore_balance,
      revert:        {
        op:      "created",
        model:   "ChoreWithdrawal",
        id:      withdrawal.id,
        summary: "put #{withdrawal.amount_pebbles}p back",
      },
    }
  },
  receipt:     ->(result, ctx) {
    payload = ctx.proposal["payload"] || {}
    spent   = "Withdrew #{payload["amount"]}p"
    spent  += " for #{payload["note"]}" if payload["note"].present?
    "#{spent} · #{result[:balance]}p left 🪨"
  },
)

require "rails_helper"

# Spending pebbles from chat, with an optional note, undoably.
RSpec.describe "Buddy withdraw_pebbles" do
  let(:user)  { create(:user) }
  let(:chore) { create(:chore, created_by_user: user, name: "Mow") }
  let(:tool)  { Buddy::Tools[:withdraw_pebbles] }

  before {
    allow(ChoreBroadcaster).to receive(:broadcast_changes!)
    allow(ChoreGoal).to receive(:refresh_all_for)
  }

  def ctx(proposal: nil)
    Buddy::ToolContext.new(user, proposal: proposal)
  end

  def earn!(pebbles)
    ChoreCompletion.create!(
      chore:        chore,
      user:         user,
      completed_at: Time.current,
      day_key:      ChoreDay.current(user),
      paid_pebbles: pebbles,
    )
  end

  def run(payload)
    confirm = tool[:confirm].call(payload, ctx)
    merged  = payload.merge(confirm[:resolved] || {})
    {
      confirm: confirm,
      merged:  merged,
      result:  tool[:execute].call(merged, ctx),
      label:   tool[:label].call(merged, ctx),
    }
  end

  it "takes the pebbles out and leaves the note that says where they went" do
    earn!(120)

    out = run({ amount: 25, note: "arcade" })

    withdrawal = ChoreWithdrawal.find(out[:result][:withdrawal_id])
    expect(withdrawal.amount_pebbles).to eq(25)
    expect(withdrawal.note).to eq("arcade")
    expect(user.reload.chore_balance).to eq(95)
    expect(out[:result][:balance]).to eq(95)
  end

  it "records a bare withdrawal when they didn't say what it was for" do
    earn!(50)

    out = run({ amount: 10 })

    expect(ChoreWithdrawal.find(out[:result][:withdrawal_id]).note).to be_nil
    expect(user.reload.chore_balance).to eq(40)
  end

  # The Balance page allows a negative balance, so this doesn't get stricter
  # than the app - but an overdraw is more often a misheard number, so the
  # confirm says so.
  it "works out what the withdrawal leaves, flagging an overdraw", :aggregate_failures do
    earn!(10)
    expect(tool[:confirm].call({ amount: 40 }, ctx)[:summary]).to include("-30p", "NEGATIVE")

    earn!(110)
    summary = tool[:confirm].call({ amount: 25 }, ctx)[:summary]
    expect(summary).to include("95p")
    expect(summary).not_to include("NEGATIVE")
  end

  it "refuses a withdrawal that isn't a positive number" do
    expect { tool[:confirm].call({ amount: 0 }, ctx) }.to raise_error(/positive/)
    expect { tool[:confirm].call({ amount: -5 }, ctx) }.to raise_error(/positive/)
  end

  # Level 2 means the row lands pre-checked and unchecking it walks the spend
  # back - a balance is exactly the kind of thing a wrong number should be
  # takeable off of.
  describe "undoing it" do
    it "puts the pebbles back when the row is unchecked" do
      earn!(120)
      out = run({ amount: 25, note: "arcade" })

      expect(Buddy::Reverter).to be_reversible(out[:result][:revert])
      Buddy::Reverter.call(out[:result][:revert])

      expect(ChoreWithdrawal.exists?(out[:result][:withdrawal_id])).to be(false)
      expect(user.reload.chore_balance).to eq(120)
    end

    # An undo has to be undoable, or it's a delete with a friendly name - and
    # the note is the part with no other copy.
    it "brings the note back when the undo is itself undone" do
      earn!(120)
      revert = run({ amount: 25, note: "arcade" })[:result][:revert]

      inverse = Buddy::Reverter.inverse(revert)
      Buddy::Reverter.call(revert)
      Buddy::Reverter.call(inverse)

      restored = user.reload.chore_withdrawals.last
      expect(restored.amount_pebbles).to eq(25)
      expect(restored.note).to eq("arcade")
      expect(user.chore_balance).to eq(95)
    end
  end

  it "hands the balance to Buddy so it can answer how many they have" do
    earn!(120)
    run({ amount: 25 })

    context = Buddy::Context.build(user, ByteConversation.create!(user: user, mode: :buddy, name: "Buddy"))
    expect(context[:pebble_balance]).to eq(95)
  end
end

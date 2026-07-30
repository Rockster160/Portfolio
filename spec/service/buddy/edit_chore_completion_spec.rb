require "rails_helper"

# Prod 1227-1235: Buddy marked two waters, forgot the "Hint Raspberry" note, and
# then spent four exchanges insisting it couldn't put the note on afterwards -
# undoing an unrelated chore along the way. There was no tool for changing a
# completion that had already landed. There is now.
RSpec.describe "Buddy edit_chore_completion" do
  let(:user)  { create(:user) }
  let(:chore) { create(:chore, created_by_user: user, name: "8oz Water") }
  let(:tool)  { Buddy::Tools[:edit_chore_completion] }

  before {
    allow(ChoreBroadcaster).to receive(:broadcast_changes!)
    allow(ChoreStreak).to receive(:rebuild_for!)
  }

  def ctx
    Buddy::ToolContext.new(user)
  end

  def complete!(at:, note: nil)
    ChoreCompletion.create!(
      chore:        chore,
      user:         user,
      completed_at: at,
      day_key:      ChoreDay.current(user, at: at),
      note:         note,
    )
  end

  def run(payload)
    confirm = tool[:confirm].call(payload, ctx)
    merged  = payload.merge(confirm[:resolved] || {})
    { confirm: confirm, merged: merged, result: tool[:execute].call(merged, ctx), label: tool[:label].call(merged, ctx) }
  end

  it "puts a note on the completion that just landed" do
    completion = complete!(at: 5.minutes.ago)

    out = run({ chore: "water", note: "Hint Raspberry" })

    expect(completion.reload.note).to eq("Hint Raspberry")
    expect(out[:result][:changed]).to eq(1)
    expect(tool[:receipt].call(out[:result], ctx)).to eq("Updated the 8oz Water completion ✓")
  end

  # complete_chore(count: 2) writes two rows, so "both of them" has to reach
  # past the single newest one.
  it "reaches back over several recent completions" do
    older  = complete!(at: 10.minutes.ago)
    newer  = complete!(at: 5.minutes.ago)
    oldest = complete!(at: 3.hours.ago)

    out = run({ chore: "water", note: "Hint Raspberry", recent: 2 })

    expect(newer.reload.note).to eq("Hint Raspberry")
    expect(older.reload.note).to eq("Hint Raspberry")
    expect(oldest.reload.note).to be_blank
    expect(out[:confirm][:summary]).to eq("Update 2 8oz Water completions?")
    expect(out[:label][:title]).to eq("2× 8oz Water")
  end

  it "corrects the time and moves the chore-day with it" do
    completion = complete!(at: 5.minutes.ago)
    target     = Buddy::TimeParser.parse_past("2 hours ago", user: user)

    run({ chore: "water", at: "2 hours ago" })

    expect(completion.reload.completed_at).to be_within(1.minute).of(target)
    expect(completion.day_key).to eq(ChoreDay.current(user, at: target))
    expect(ChoreStreak).to have_received(:rebuild_for!).with(user, chore)
  end

  it "refuses a call that changes nothing" do
    complete!(at: 5.minutes.ago)

    expect { tool[:confirm].call({ chore: "water" }, ctx) }
      .to raise_error(/pass a note or a time/)
  end

  it "says so when there's no completion to edit" do
    expect { tool[:confirm].call({ chore: "water", note: "x" }, ctx) }
      .to raise_error(/no matching completion/)
  end

  it "asks for fewer than requested rather than failing when only one exists" do
    complete!(at: 5.minutes.ago)

    out = run({ chore: "water", note: "Hint Raspberry", recent: 2 })

    expect(out[:result][:changed]).to eq(1)
    expect(out[:confirm][:summary]).to eq("Update the 8oz Water completion?")
  end

  describe "undo" do
    it "restores every note it overwrote, not just the first" do
      first  = complete!(at: 10.minutes.ago, note: "plain")
      second = complete!(at: 5.minutes.ago, note: "also plain")

      out = run({ chore: "water", note: "Hint Raspberry", recent: 2 })
      Buddy::Reverter.descriptors(out[:result].stringify_keys).each { |rv| Buddy::Reverter.call(rv) }

      expect(first.reload.note).to eq("plain")
      expect(second.reload.note).to eq("also plain")
    end

    it "is what the undo tool finds on the proposal" do
      complete!(at: 5.minutes.ago, note: "plain")
      out = run({ chore: "water", note: "Hint Raspberry" })

      conversation = user.byte_conversations.create!(mode: :buddy, name: "Buddy")
      action = ByteAction.create!(
        user:              user,
        byte_conversation: conversation,
        tool_name:         "buddy_proposals",
        kind:              :custom,
        state:             :pending,
        buttons:           [{ "id" => 1, "result" => out[:result].deep_stringify_keys }],
      )

      found = Buddy::Reverter.most_recent(conversation)
      expect(found[:action_id]).to eq(action.id)

      Buddy::Reverter.perform!(action.id, 1)
      expect(ChoreCompletion.last.note).to eq("plain")
    end
  end
end

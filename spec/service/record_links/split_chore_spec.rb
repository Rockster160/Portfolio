require "rails_helper"

# Logging "Teeth" stopped ticking the teeth chore, and nothing looked broken.
#
# The chore had been split into per-person sub-chores that morning — one Teeth
# for each of them under a parent that holds them. The link still matched, the
# completion still got written, and it landed on the PARENT: a container that
# is `show_on_today_view: never`, so the row was real, correct-looking in the
# database, and invisible on the only screen anybody reads.
#
# The card that stayed unticked reads its own completions only (a leaf matches
# `chore_id`, a parent matches `chore_id OR parent_chore_id`), so a completion
# on the family credits nobody in it.
RSpec.describe "Logging an event for a chore that's been split per person" do
  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(ActionCable.server).to receive(:broadcast)
    allow(ActionEventBroadcastWorker).to receive(:perform_async)
    allow(ChoreBroadcaster).to receive(:broadcast_changes!)
    RecordLink.delete_all
    user.action_events.delete_all
    ChoreCompletion.where(user_id: user.id).delete_all
    Chore.where(chore_household: household).delete_all
    RecordLinks::Guard.reset!

    ChoreHouseholdMembership.find_or_create_by!(chore_household: household, user: partner) { |m| m.role = :member }
    partner.update!(chore_household_id: household.id)
  end

  let(:user)      { User.me }
  let(:partner)   { create(:user) }
  let(:household) { user.chore_household }

  let!(:parent) {
    Chore.create!(
      chore_household: household, created_by_user: user, name: "Teeth", show_on_today_view: :never,
    )
  }
  let!(:mine) {
    Chore.create!(
      chore_household: household, created_by_user: user, name: "Teeth",
      parent_chore: parent, assigned_to_user: user
    )
  }
  let!(:theirs) {
    Chore.create!(
      chore_household: household, created_by_user: partner, name: "Teeth",
      parent_chore: parent, assigned_to_user: partner
    )
  }
  let!(:link) {
    RecordLink.create!(
      user: user, source_kind: :event, source_name: "Teeth", target_kind: :chore, target_name: "Teeth",
    )
  }

  def log_teeth!(at: Time.current)
    event = user.action_events.create!(name: "Teeth", timestamp: at)
    ActionEventNotifier.notify(user, event, :added)
    event
  end

  def completions_on(chore)
    ChoreCompletion.where(chore_id: chore.id)
  end

  it "ticks off the sub-chore that belongs to whoever logged it" do
    log_teeth!

    expect(completions_on(mine).count).to eq(1)
    expect(completions_on(mine).first.user_id).to eq(user.id)
  end

  it "leaves the container alone, and the other person's" do
    log_teeth!

    expect(completions_on(parent)).to be_empty
    expect(completions_on(theirs)).to be_empty
  end

  # The whole point: the parent's card would have read as done off its own row
  # while the leaf on Today read as not done.
  it "puts the row where the card that's on screen will find it" do
    log_teeth!

    expect(ChoreCompletion.where("chore_id = :id OR parent_chore_id = :id", id: mine.id)).to be_present
  end

  # Deleting the event has to find the row it made, which is no longer on the
  # chore the link names.
  it "takes the completion back off when the event is deleted" do
    event = log_teeth!

    event.destroy!
    ActionEventNotifier.notify(user, event, :removed)

    expect(completions_on(mine)).to be_empty
  end

  it "still moves the completion when the event's time is edited" do
    event = log_teeth!
    was   = event.timestamp

    event.update!(timestamp: was - 2.hours)
    ActionEventNotifier.notify(user, event, :changed)

    expect(completions_on(mine).count).to eq(1)
    expect(completions_on(mine).first.completed_at).to be_within(2.seconds).of(was - 2.hours)
  end

  # The narrow half of the rule. Splitting a chore by ITEM rather than by
  # person - Supplements holding Focus and Cymbalta - assigns nothing to
  # anybody, and picking one of those on a name match is how you log the wrong
  # medication.
  context "when the sub-chores are per item rather than per person" do
    let!(:supplements) { Chore.create!(chore_household: household, created_by_user: user, name: "Supplements") }
    let!(:focus_med) {
      Chore.create!(chore_household: household, created_by_user: user, name: "Focus", parent_chore: supplements)
    }

    it "does not guess, and completes the chore the link actually names" do
      RecordLink.create!(
        user:        user, source_kind: :event, source_name: "Supplements",
        target_kind: :chore, target_name: "Supplements"
      )
      event = user.action_events.create!(name: "Supplements", timestamp: Time.current)
      ActionEventNotifier.notify(user, event, :added)

      expect(completions_on(supplements).count).to eq(1)
      expect(completions_on(focus_med)).to be_empty
    end
  end

  describe "Chore#completion_leaf_for" do
    it "hands back the sub-chore assigned to that person" do
      expect(parent.completion_leaf_for(user)).to eq(mine)
      expect(parent.completion_leaf_for(partner)).to eq(theirs)
    end

    it "hands back the chore itself when nothing under it is theirs" do
      stranger = create(:user)

      expect(parent.completion_leaf_for(stranger)).to eq(parent)
    end

    # An explicit tap already carries the id somebody chose.
    it "never redirects a sub-chore to a sibling" do
      expect(mine.completion_leaf_for(partner)).to eq(mine)
    end

    it "no-ops without a person" do
      expect(parent.completion_leaf_for(nil)).to eq(parent)
    end

    # An archived split is a split that's over.
    it "ignores an archived sub-chore" do
      mine.update!(archived_at: Time.current)

      expect(parent.reload.completion_leaf_for(user)).to eq(parent)
    end
  end
end

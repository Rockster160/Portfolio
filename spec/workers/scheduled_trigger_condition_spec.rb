require "rails_helper"

# The Jil half of the same idea: a ScheduledTrigger is scheduled once and fires
# later, so anything it depends on was true when it was SET rather than when it
# runs. A pre-event nudge for a chore that got done in the meantime is the same
# failure as a reminder that reads its "if" out loud.
RSpec.describe "ScheduledTrigger conditions" do
  let(:user)       { create(:user) }
  let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: user) }
  let!(:chore) {
    create(:chore, created_by_user: user, chore_household: household, name: "Charge Villager Car")
  }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(::Jil::Schedule).to receive(:broadcast)
    allow(::Jil).to receive(:trigger).and_return(true)
    user.update!(chore_household_id: household.id)
  end

  def condition(over = {})
    { "find" => "chore_completions", "query" => "name:\"Charge Villager Car\" is:today", "expect" => "missing" }.merge(over)
  end

  def trigger!(**attrs)
    ScheduledTrigger.create!(
      user: user, trigger: "custom", execute_at: 1.minute.ago, data: {}, **attrs
    )
  end

  def completed!
    ChoreCompletion.create!(
      chore: chore, user: user, completed_at: Time.current, day_key: ChoreDay.current(user),
    )
  end

  def run!
    JilRunnerWorker.new.execute_continually(user)
  end

  # Every assertion here is scoped to this trigger's own name rather than to any
  # call at all: completing a chore fires `chore_completion` through the same
  # method, so a bare `have_received(:trigger)` counts the setup as the thing
  # under test and passes for the wrong reason.
  it "fires while the condition holds" do
    trigger!(condition: condition)

    run!

    expect(::Jil).to have_received(:trigger).with(user, "custom", hash_including(:timestamp), any_args)
  end

  it "does not fire once the condition stops holding" do
    completed!
    trigger!(condition: condition)

    run!

    expect(::Jil).not_to have_received(:trigger).with(user, "custom", any_args)
  end

  # A skipped trigger is a FINISHED trigger. Left un-started or un-completed it
  # would be picked up again on the next sweep, every few seconds, forever —
  # and nothing downstream should have to learn a third state.
  it "completes the row either way, so a skipped one isn't stuck" do
    completed!
    sched = trigger!(condition: condition)

    run!

    expect(sched.reload.started_at).to be_present
    expect(sched.completed_at).to be_present
  end

  it "leaves a trigger with no condition alone" do
    completed!
    trigger!

    run!

    expect(::Jil).to have_received(:trigger).with(user, "custom", any_args).once
  end

  # Same call as the reminder path and for the same reason: a trigger that
  # silently didn't run is indistinguishable from one that never existed, and
  # something downstream is usually waiting on it.
  it "fires anyway when the condition can't be evaluated" do
    trigger!(condition: condition("find" => "nonsense"))

    run!

    expect(::Jil).to have_received(:trigger).with(user, "custom", any_args).once
  end
end

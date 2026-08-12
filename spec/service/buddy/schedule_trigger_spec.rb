require "rails_helper"

# A PURE trigger: a raw scope put on the clock, optionally behind a check.
#
# "If I've done the villager car by 8, fire villager:car:charged" needs no task
# to be named and no access to be granted — a trigger is an announcement, not a
# call. `trigger_jil_task` can only reach what's in the person's `jil_triggers`
# index, which is the right gate for "run this automation now" and the wrong one
# for "publish this event". Whatever is listening runs as its own owner, exactly
# as it would if the trigger came from anywhere else.
RSpec.describe "schedule_trigger" do
  let(:user)       { create(:user) }
  let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: user) }
  let!(:convo) {
    user.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: Time.current)
  }
  let!(:chore) {
    create(:chore, created_by_user: user, chore_household: household, name: "Charge Villager Car")
  }
  let(:ctx)  { Buddy::ToolContext.new(user, conversation: convo) }
  let(:tool) { Buddy::Tools[:schedule_trigger] }
  let(:at)   { 3.hours.from_now.iso8601 }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(::Jil).to receive(:trigger).and_return(true)
    allow(::Jil::Schedule).to receive(:add_job)
    user.update!(chore_household_id: household.id)
  end

  def confirm(payload) = tool[:confirm].call({ at: at }.merge(payload), ctx)

  def create!(payload)
    args = { at: at }.merge(payload)
    tool[:execute].call(args.merge(confirm(payload)[:resolved]), ctx)
  end

  def scheduled = ScheduledTrigger.where(user_id: user.id)

  describe "the trigger itself" do
    it "schedules a raw scope with no task named anywhere" do
      create!(scope: "villager")

      expect(scheduled.count).to eq(1)
      expect(scheduled.first.trigger).to eq("villager")
    end

    # The gate `trigger_jil_task` applies is the whole point of NOT applying it
    # here. Nothing in this path consults the index.
    it "schedules a scope that matches no task the person can reach" do
      expect { create!(scope: "nothing:listens:to:this") }.to change { scheduled.count }.by(1)
    end

    # A listener reads `scope:rest` as a scope plus a filter, and that's how a
    # person says one out loud too.
    it "splits a colon-separated scope the way a listener reads it" do
      create!(scope: "villager:car:charged")
      row = scheduled.first

      expect(row.trigger).to eq("villager")
      expect(row.data).to include("car" => "charged")
    end

    it "merges explicit data over what the scope carried" do
      create!(scope: "villager:car:charged", data: "who:rocco")
      row = scheduled.first

      expect(row.data).to include("car" => "charged", "who" => "rocco")
    end

    it "fires at the time it was given" do
      create!(scope: "villager")

      expect(scheduled.first.execute_at).to be_within(2.seconds).of(Time.zone.parse(at))
    end

    # Creating the row is only half of scheduling one - something has to put a
    # runner on the clock. Jil::Schedule owns both halves and the split between
    # them: anything inside REDIS_OFFSET gets a Sidekiq job now...
    it "puts a runner on the clock for something firing soon" do
      create!(scope: "villager", at: 3.minutes.from_now.iso8601)

      expect(::Jil::Schedule).to have_received(:add_job)
    end

    # ...and anything further out is deliberately left for JilScheduleWorker's
    # every-minute sweep, which is what stops a trigger set for next month from
    # sitting in Redis for a month. Built by hand with ScheduledTrigger.create!
    # it would be in neither place.
    it "leaves one further out for the every-minute sweep to pick up" do
      create!(scope: "villager")

      expect(::Jil::Schedule).not_to have_received(:add_job)
      expect(ScheduledTrigger.not_scheduled.where(user_id: user.id)).to include(scheduled.first)
    end

    it "refuses a time that has already gone" do
      expect { confirm(scope: "villager", at: 2.hours.ago.iso8601) }.to raise_error(/already passed/)
    end

    it "refuses an empty scope" do
      expect { confirm(scope: " ") }.to raise_error(/needs a scope/)
    end
  end

  describe "with a check on it" do
    let(:checked) {
      {
        scope:        "villager:car:charged",
        check:        :chore_completions,
        check_query:  %q{name:"Charge Villager Car" is:today},
        check_expect: :found,
      }
    }

    def completed!
      ChoreCompletion.create!(
        chore: chore, user: user, completed_at: Time.current, day_key: ChoreDay.current(user),
      )
    end

    def run! = JilRunnerWorker.new.execute_continually(user)

    it "stores the check on the scheduled row" do
      create!(checked)

      expect(scheduled.first.condition).to include(
        "kind" => "search", "find" => "chore_completions", "expect" => "found",
      )
    end

    it "says what it will look at before they tap yes" do
      expect(confirm(checked)[:summary]).to include("any chore completions", "villager")
    end

    # The whole sentence, end to end: at 8 it looks, and it fires only if the
    # chore actually got done.
    it "fires when the chore was done" do
      create!(checked)
      completed!
      scheduled.first.update!(execute_at: 1.minute.ago)

      run!

      expect(::Jil).to have_received(:trigger).with(user, "villager", any_args)
    end

    it "stays quiet when it wasn't" do
      create!(checked)
      scheduled.first.update!(execute_at: 1.minute.ago)

      run!

      expect(::Jil).not_to have_received(:trigger).with(user, "villager", any_args)
    end

    # A skip is invisible by design, and invisible is how a check that's quietly
    # wrong stays wrong.
    it "leaves a receipt when it skips" do
      create!(checked)
      scheduled.first.update!(execute_at: 1.minute.ago)

      run!

      chip = convo.byte_messages.where(direction: :inbound).last
      expect(chip.metadata["kind"]).to eq("buddy_activity")
      expect(chip.metadata["ok"]).to be(false)
      expect(chip.metadata["detail"]).to include("any chore completions")
    end

    it "refuses a check that is both a search and a task" do
      expect { confirm(checked.merge(check_task: "Something")) }.to raise_error(/not both/)
    end

    it "leaves an unchecked trigger with no condition at all" do
      create!(scope: "villager")

      expect(scheduled.first.condition).to be_nil
    end
  end
end

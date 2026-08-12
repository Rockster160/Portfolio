require "rails_helper"

# The tool has to be able to EXPRESS the thing, or the mechanism behind it never
# gets used. Prod 42/43/44 were three unconditional reminders because that was
# the only shape `schedule_reminder` offered.
#
# Conditions are validated HERE, on the way in, rather than at fire time. An
# authoring mistake caught while the person is still in the conversation is a
# sentence; caught at 9pm three weeks later its only symptom is a reminder that
# quietly never came.
RSpec.describe "schedule_reminder conditions and windows" do
  let(:user)       { create(:user) }
  let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: user) }
  let!(:convo) {
    user.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: Time.current)
  }
  let!(:chore) {
    create(:chore, created_by_user: user, chore_household: household, name: "Charge Villager Car")
  }
  let(:ctx)  { Buddy::ToolContext.new(user, conversation: convo) }
  let(:tool) { Buddy::Tools[:schedule_reminder] }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    user.update!(chore_household_id: household.id)
  end

  def confirm(payload)
    tool[:confirm].call({ text: "Charge the village car" }.merge(payload), ctx)
  end

  def create!(payload)
    resolved = confirm(payload)[:resolved]
    tool[:execute].call({ text: "Charge the village car" }.merge(payload).merge(resolved), ctx)
  end

  describe "the condition" do
    let(:checked) {
      {
        repeat:       "daily:21:00",
        check:        :chore_completions,
        check_query:  %q{name:"Charge Villager Car" is:today},
        check_expect: :missing,
      }
    }

    it "stores it on the reminder" do
      result = create!(checked)

      expect(BuddyReminder.find(result[:reminder_id]).condition).to eq(
        "find"  => "chore_completions",
        "query" => %q{name:"Charge Villager Car" is:today},
        "kind"  => "search",
        "expect" => "missing",
      )
    end

    # The confirm card is where the person sees what they're agreeing to, and
    # "remind me at 9" reads identically whether or not it will check anything.
    it "says out loud what it will check before they tap yes" do
      expect(confirm(checked)[:summary]).to include("no chore completions")
    end

    it "refuses a check with nothing to search for" do
      expect { confirm(checked.merge(check_query: nil)) }.to raise_error(/needs a query/)
    end

    # Validated by actually RUNNING it once here, so a query that blows up in
    # SQL does so in the conversation rather than three weeks later at 9pm.
    it "runs the query once before agreeing to store it" do
      allow(ScheduleCondition).to receive(:met?).and_call_original

      confirm(checked)

      expect(ScheduleCondition).to have_received(:met?)
    end

    # Worth pinning because it is NOT an error and reads like one. The query
    # syntax treats an unrecognised field as free text everywhere in this app
    # (see ApplicationRecord.node_sql), so a typo'd `chore:` narrows to a text
    # search rather than raising - the condition still evaluates, it just
    # answers a looser question than intended.
    it "takes an unknown field as free text, the way every other search does" do
      expect { confirm(checked.merge(check_query: "wat:nonsense")) }.not_to raise_error
    end

    it "leaves an unchecked reminder with no condition at all" do
      result = create!(repeat: "daily:21:00")

      expect(BuddyReminder.find(result[:reminder_id]).condition).to be_nil
    end
  end

  # The search sets can only ever cover rows in this app. A Jil function is
  # whatever the person wired — a sensor, a device, an API, a calculation.
  describe "gating on one of their own tasks" do
    # A real row rather than a stub, because what makes a task reachable here is
    # three scopes agreeing (`accessible_tasks`, `buddy_visible`, `functions`)
    # and a double would assert nothing about that.
    let!(:task) {
      Task.create!(
        user: user, name: "Is The Car Plugged In", buddy_enabled: true,
        listener: "function()", code: "",
      )
    }

    it "stores the task name rather than a resolved id" do
      result = create!(repeat: "daily:21:00", check_task: "Is The Car Plugged In", check_expect: :falsy)

      expect(BuddyReminder.find(result[:reminder_id]).condition).to include(
        "kind" => "jil", "task" => "Is The Car Plugged In", "expect" => "falsy",
      )
    end

    it "says what it will ask before they tap yes" do
      expect(confirm(repeat: "daily:21:00", check_task: "Is The Car Plugged In")[:summary])
        .to include("Is The Car Plugged In")
    end

    # Checked at authoring time — the half that can be wrong forever. The
    # function itself is NOT run here: asking one isn't free, and a reminder set
    # for next Tuesday shouldn't fire it today to prove it can.
    it "refuses a task name that resolves to nothing" do
      expect { confirm(repeat: "daily:21:00", check_task: "Nothing By That Name") }
        .to raise_error(/no Jil function matches/)
    end

    it "does not run the function just to validate it" do
      allow(task).to receive(:execute)

      confirm(repeat: "daily:21:00", check_task: "Is The Car Plugged In")

      expect(task).not_to have_received(:execute)
    end

    it "refuses a check that is both a search and a task" do
      expect { confirm(repeat: "daily:21:00", check: :chore_completions, check_query: "x", check_task: "y") }
        .to raise_error(/not both/)
    end
  end

  describe "the intraday window" do
    let(:hourly) { { repeat: "daily:21:00", every_minutes: 60, until_time: "23:00" } }

    it "is one reminder covering 9, 10 and 11" do
      result = create!(hourly)
      reminder = BuddyReminder.find(result[:reminder_id])

      expect(BuddyReminder.where(user_id: user.id).count).to eq(1)
      expect(reminder.recurrence["every_minutes"]).to eq(60)
      expect(reminder.recurrence["until_at"]).to eq("23:00")
    end

    # `at` is where the window starts, and that's the repeat spec's to give.
    it "refuses a window with no repeat to start from" do
      expect { confirm(every_minutes: 60, until_time: "23:00", at: 1.hour.from_now.iso8601) }
        .to raise_error(/needs a `repeat`/)
    end

    it "refuses half a window, which would silently do nothing" do
      expect { confirm(repeat: "daily:21:00", every_minutes: 60) }.to raise_error(/go together/)
      expect { confirm(repeat: "daily:21:00", until_time: "23:00") }.to raise_error(/go together/)
    end

    it "refuses a window that ends before it starts" do
      expect { confirm(hourly.merge(until_time: "19:00")) }.to raise_error(/is not after/)
    end

    it "refuses a time it can't read" do
      expect { confirm(hourly.merge(until_time: "elevenish")) }.to raise_error(/want HH:MM/)
    end
  end

  # The whole point of the pairing: one row, conditional, that stops for the
  # night on its own — which is what those three rows should have been.
  it "builds the reminder that should have been set in the first place" do
    result = create!(
      repeat:        "daily:21:00",
      every_minutes: 60,
      until_time:    "23:00",
      until:         Date.current.iso8601,
      check:         :chore_completions,
      check_query:   %q{name:"Charge Villager Car" is:today},
      check_expect:  :missing,
    )
    reminder = BuddyReminder.find(result[:reminder_id])

    expect(reminder.intraday?).to be(true)
    expect(reminder.conditional?).to be(true)
    expect(reminder.recurrence["until_on"]).to eq(Date.current.iso8601)
  end
end

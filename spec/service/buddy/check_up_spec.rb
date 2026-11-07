require "rails_helper"

# Questions about how someone is, put on the clock: each asking is a Prompt
# posted as a form, fired off a reminder with no model turn.
RSpec.describe Buddy::CheckUp do
  let(:user) { create(:user) }
  let!(:convo) {
    user.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: Time.current)
  }
  let(:ctx) { Buddy::ToolContext.new(user, conversation: convo) }
  let(:tool) { Buddy::Tools[:schedule_check_up] }
  let(:symptoms) { "Headache\nCough\nThroat | scale 1-5" }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(WebPushNotifications).to receive(:send_to_byte)
    allow(Buddy::Features).to receive(:enabled?).and_call_original
    allow(Buddy::Features).to receive(:enabled?).with(user, :prompts).and_return(true)
    allow(Jil).to receive(:trigger)
  end

  def schedule!(payload={})
    args = { title: "Sick check-up", questions: symptoms, repeat: "daily:09:00\ndaily:21:00" }.merge(payload)
    result = tool[:execute].call(args.merge(tool[:confirm].call(args, ctx)[:resolved]), ctx)
    BuddyReminder.where(id: result[:reminder_ids]).order(:id).to_a
  end

  def fire!(reminder)
    reminder.update!(fire_at: 1.minute.ago)
    Buddy::ReminderFirer.fire!(reminder.reload)
  end

  def asked
    described_class.asked(user, "Sick check-up").order(:id)
  end

  describe "reading the questions" do
    it "rates by default and reads each other way of answering", :aggregate_failures do
      options = described_class.questions(
        "Headache\nEnergy | scale 1-5\nOn your mind? | text\nStarted? | yes/no\nFlow | pick: Light, Heavy\nFirst day | date",
      )

      expect(options.pluck(:type)).to eq(%i[scale scale text checkbox chips date text])
      expect(options.first).to include(min: 0, max: 10)
      expect(options.second).to include(min: 1, max: 5)
      expect(options.fifth[:choices]).to eq(%w[Light Heavy])
      expect(options.last[:question]).to eq("Notes")
    end

    it "refuses a line it can't read, while they're still there to fix it", :aggregate_failures do
      expect { described_class.questions("Mood | vibes") }.to raise_error(/couldn't read how to answer/)
      expect { described_class.questions("Flow | pick: heavy") }.to raise_error(/two things/)
      expect { described_class.questions(" \n ") }.to raise_error(/at least one question/)
    end
  end

  describe "putting it on the clock" do
    it "is one reminder per time of day, both asking the same questions", :aggregate_failures do
      reminders = schedule!

      expect(reminders.map { |r| r.fire_at.in_time_zone(user.timezone).strftime("%H:%M") }).to contain_exactly("09:00", "21:00")
      expect(reminders.map(&:action).uniq.length).to eq(1)
      expect(reminders.first.action.first).to include("tool" => "ask_check_up")
      expect(reminders.first.action.first["payload"]).to include("title" => "Sick check-up", "questions" => symptoms)
      expect(Prompt.count).to eq(0)
    end

    it "waits for the day they said it starts" do
      starts = user.perceived_today + 9
      reminder = schedule!(repeat: "every:4-weeks:09:00", starts: starts.iso8601).first

      expect(reminder.fire_at.in_time_zone(user.timezone).to_date).to eq(starts)
    end

    it "refuses an unreadable repeat or no time at all", :aggregate_failures do
      expect { schedule!(repeat: "now and then") }.to raise_error(/unknown repeat spec/)
      expect { schedule!(repeat: nil) }.to raise_error(/needs a `repeat` or an `at`/)
    end
  end

  describe "when it comes round" do
    it "posts the questions as a form and rolls on to the next day", :aggregate_failures do
      reminder = schedule!.first
      expect(Buddy::PromptDelivery).to receive(:post!).and_call_original

      fire!(reminder)

      prompt = asked.sole
      expect(prompt.question).to eq("Sick check-up")
      expect(prompt.options.pluck("question")).to eq(%w[Headache Cough Throat Notes])
      expect(ByteAction.where(user: user, tool_name: Buddy::FormAction::TOOL_NAME).count).to eq(1)
      expect(reminder.reload.fire_at).to be > Time.current
    end

    it "asks an unanswered one again rather than stacking a second" do
      morning, evening = schedule!
      fire!(morning)
      fire!(evening)

      expect(asked.count).to eq(1)
    end

    it "opens the next one on the last ratings", :aggregate_failures do
      reminder = schedule!.first
      fire!(reminder)
      asked.sole.update!(response: { "Headache" => "6", "Cough" => "2", "Throat" => "4", "Notes" => "ugh" })

      fire!(reminder)

      options = asked.last.options.index_by { |o| o["question"] }
      expect(asked.count).to eq(2)
      expect(options["Headache"]["default"]).to eq(6)
      expect(options["Throat"]["default"]).to eq(4)
      expect(options["Notes"]["default"]).to eq("")
    end
  end

  describe "changing one by talking to it" do
    def change!(payload)
      args = { title: "sick check-up" }.merge(payload)
      tool[:execute].call(args.merge(tool[:confirm].call(args, ctx)[:resolved]), ctx)
    end

    def questions_now
      BuddyReminder.pending.where(user: user).map { |r| r.action.first["payload"]["questions"] }.uniq
    end

    it "changes the questions it names and keeps the rest and its times", :aggregate_failures do
      before = schedule!.map(&:fire_at)

      result = change!(questions: "Headache | scale 1-100\nCough | yes/no")

      expect(questions_now).to eq(["Headache | scale 1-100\nCough | yes/no\nThroat | scale 1-5"])
      expect(BuddyReminder.pending.where(user: user).order(:id).map(&:fire_at)).to eq(before)
      expect(BuddyReminder.pending.where(user: user).first.body).to eq("Check-up: Sick check-up - Headache, Cough, Throat")
      expect(tool[:receipt].call(result, ctx)).to include("now asks Headache, Cough, and Throat")
    end

    it "adds a new question, drops one by name, and moves to new times", :aggregate_failures do
      schedule!

      change!(questions: "Fever", remove: "cough", repeat: "daily:12:00")

      reminders = BuddyReminder.pending.where(user: user)
      expect(reminders.count).to eq(1)
      expect(reminders.sole.recurrence).to include("at" => "12:00")
      expect(questions_now).to eq(["Headache\nThroat | scale 1-5\nFever"])
    end

    it "names the ones running when the title matches none" do
      schedule!

      expect { change!(title: "Allergies", questions: "Sneezing") }.to raise_error(/the ones running are Sick check-up/)
    end

    it "doesn't open a changed scale on a rating from the old one", :aggregate_failures do
      reminder = schedule!.first
      fire!(reminder)
      asked.sole.update!(response: { "Headache" => "6", "Cough" => "2", "Throat" => "4" })

      change!(questions: "Headache | scale 1-100")
      fire!(reminder.reload)

      options = asked.last.options.index_by { |o| o["question"] }
      expect(options["Headache"]).not_to have_key("default")
      expect(options["Cough"]["default"]).to eq(2)
    end
  end
end

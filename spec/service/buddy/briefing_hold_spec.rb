require "rails_helper"

# A morning briefing that waits for a check-in, and is written knowing how it
# went.
RSpec.describe Buddy::BriefingHold do
  let(:user)   { create(:user) }
  let!(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }
  let!(:reminder) { Buddy::TodaySchedule.ensure!(user) }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(WebPushNotifications).to receive(:send_to_byte)
    allow(BuddyDeliverWorker).to receive(:perform_async)
  end

  def seeds
    convo.byte_messages.where("metadata ->> 'buddy_action' = 'today'")
  end

  # What a check-in task does on `briefing:due`: ask something that holds it.
  def listen_with_check_in!
    user.tasks.create!(
      name:     "Check-in",
      listener: "briefing:due",
      enabled:  true,
      code:     <<~'JIL',
        askData = Hash.new({
          askHolds = Keyval.new("holds_briefing", true)::Keyval
          askQueue = Keyval.new("queue", "morning")::Keyval
        })::Hash
        asked = Prompt.create("Morning check-in", askData, {
          askFeeling = PromptQuestion.scale("Feeling", 0, 10, 5, true)::PromptQuestion
          askSound = PromptQuestion.scale("Sound", 0, 10, 5, true)::PromptQuestion
        }, true)::Prompt
      JIL
    )
  end

  def answer(prompt, response)
    prompt.update!(response: response)
    Jil.trigger(user, :prompt, prompt.with_jil_attrs(status: :complete))
  end

  it "goes out on time when nothing asks first" do
    Buddy::ReminderFirer.fire!(reminder)

    expect(seeds.count).to eq(1)
  end

  it "waits for the check-in, then goes out with what they said", :aggregate_failures do
    listen_with_check_in!

    Buddy::ReminderFirer.fire!(reminder)

    expect(seeds).to be_empty
    asked = user.prompts.unanswered.find_by!(question: "Morning check-in")

    answer(asked, { "Feeling" => "3" })

    expect(seeds.count).to eq(1)
    seed = seeds.first
    expect(seed.body).to include("HOW THEY ARE\n- Morning check-in: Feeling: 3 of 10")
    expect(seed.body).not_to include("Sound")
    expect(seed.body).to include("Let it set how you talk to them")
    expect(seed.metadata["source"]).to eq("today_scheduled")
    expect(reminder.reload.metadata).not_to have_key("held")
  end

  it "goes out in the thread that's theirs when they answer, not the one it was held in" do
    listen_with_check_in!
    Buddy::ReminderFirer.fire!(reminder)
    newer = user.byte_conversations.create!(mode: :buddy, name: "Kumoko", last_message_at: Time.current)
    ByteConversation.pin_primary!(newer)

    answer(user.prompts.unanswered.find_by!(question: "Morning check-in"), { "Feeling" => "6" })

    expect(seeds).to be_empty
    expect(newer.byte_messages.where("metadata ->> 'buddy_action' = 'today'").count).to eq(1)
  end

  it "keeps waiting through the follow-ups the check-in asks" do
    listen_with_check_in!
    Buddy::ReminderFirer.fire!(reminder)
    asked = user.prompts.unanswered.find_by!(question: "Morning check-in")

    asked.update!(response: { "Feeling" => "2" })
    follow_up = user.prompts.create!(
      question: "Meltdown", params: { holds_briefing: true, queue: "morning" }, options: [],
    )
    Jil.trigger(user, :prompt, asked.with_jil_attrs(status: :complete))

    expect(seeds).to be_empty

    follow_up.destroy
    Jil.trigger(user, :prompt, follow_up.with_jil_attrs(status: :skip))

    expect(seeds.count).to eq(1)
  end

  it "goes out once however many endings arrive" do
    listen_with_check_in!
    Buddy::ReminderFirer.fire!(reminder)
    asked = user.prompts.unanswered.find_by!(question: "Morning check-in")

    answer(asked, { "Feeling" => "3" })
    Jil.trigger(user, :prompt, asked.with_jil_attrs(status: :complete))

    expect(seeds.count).to eq(1)
  end

  it "is not held by one left unanswered yesterday" do
    user.prompts.create!(question: "Morning check-in", params: { holds_briefing: true }, options: [], created_at: 2.days.ago)

    Buddy::ReminderFirer.fire!(reminder)

    expect(seeds.count).to eq(1)
  end

  it "doesn't ask anything when they ask for it by name" do
    listen_with_check_in!

    msg = Buddy::TodayBriefing.deliver!(user, convo, scheduled: true)

    expect(msg).to be_present
    expect(user.prompts).to be_empty
  end
end

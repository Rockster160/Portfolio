require "rails_helper"

RSpec.describe Buddy::PromptQueue do
  let(:user) { User.me }
  let!(:conversation) {
    user.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: Time.current)
  }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(WebPushNotifications).to receive(:send_to_byte)
  end

  def ask(title, queue: :check_in)
    user.prompts.create!(
      question: title,
      params:   { queue: queue }.compact,
      options:  [{ type: :text, question: "Notes", default: "" }],
    )
  end

  def posted?(prompt)
    Buddy::PromptDelivery.open_forms(user, prompt.id).exists?
  end

  def answer(prompt)
    prompt.update!(response: { "Notes" => "done" })
    Jil.trigger(user, :prompt, prompt.with_jil_attrs(status: :complete))
  end

  it "asks one at a time, in the order they were made" do
    first  = ask("Period")
    second = ask("Meltdown")

    expect(Buddy::PromptDelivery.post!(user, first)).to be_present
    expect(Buddy::PromptDelivery.post!(user, second)).to be_nil
    expect(posted?(second)).to be(false)

    answer(first)

    expect(posted?(second)).to be(true)
    expect(WebPushNotifications).to have_received(:send_to_byte).twice
  end

  it "asks the next one when the one ahead is skipped" do
    first  = ask("Period")
    second = ask("Meltdown")
    Buddy::PromptDelivery.post!(user, first)

    first.destroy
    Jil.trigger(user, :prompt, first.with_jil_attrs(status: :skip))

    expect(posted?(second)).to be(true)
    expect(Buddy::PromptDelivery.open_forms(user, second.id).count).to eq(1)
  end

  it "never holds a prompt from another queue, or one with none" do
    ask("Period")

    expect(described_class.waiting?(ask("Who did it?", queue: :chores))).to be(false)
    expect(described_class.waiting?(ask("Who did it?", queue: nil))).to be(false)
  end

  it "pushes only the one being asked when a task makes several" do
    Jil::Executor.call(
      user,
      <<~'JIL',
        firstData = Hash.new({
          firstQueue = Keyval.new("queue", "check_in")::Keyval
        })::Hash
        first = Prompt.create("Period", firstData, {
          firstNotes = PromptQuestion.text("Notes", "")::PromptQuestion
        }, true)::Prompt
        second = Prompt.create("Meltdown", firstData, {
          secondNotes = PromptQuestion.text("Notes", "")::PromptQuestion
        }, true)::Prompt
      JIL
    )

    expect(WebPushNotifications).to have_received(:send_to_byte).once
  end
end

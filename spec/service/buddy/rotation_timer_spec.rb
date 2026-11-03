require "rails_helper"

RSpec.describe Buddy::RotationTimer do
  # A countdown on the hero that ends with a question, and a
  # second press of the button that means "I rotated it".
  let(:user) { User.me }
  let!(:convo) {
    user.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: Time.current)
  }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(WebPushNotifications).to receive(:send_to_byte)
    allow(WebPushNotifications).to receive(:update_count)
    allow(::Jil).to receive(:trigger)
    convo.update_columns(buddy_theme: "byte")
  end

  # Real timers, and the suite runs Sidekiq inline — a 75-minute countdown would
  # have TimerFireWorker reschedule itself forever.
  around { |example| Sidekiq::Testing.fake! { example.run } }

  def start!(seconds: 4500, item: "Fold Laundry", list: "TODO")
    described_class.start!(
      user:         user,
      key:          "laundry",
      label:        "Rotate Laundry",
      seconds:      seconds,
      again:        "Rotated",
      follow_up:    { item: item, list: list },
      conversation: convo,
    )
  end

  def card
    ByteAction.where(tool_name: described_class::TOOL_NAME).order(:id).last
  end

  def said
    convo.byte_messages.where(direction: :inbound).order(:id)
  end

  def tap!(action, value)
    action.apply_decision!(value: value, source: :user)
    described_class.tapped!(action)
  end

  describe "starting one" do
    it "is a visible Buddy timer carrying its follow-up, with a receipt", :aggregate_failures do
      timer = start!
      spec = described_class.spec_for(timer)

      expect(timer.duration_ms).to eq(4_500_000)
      expect(timer.name).to eq("Rotate Laundry")
      expect(timer).to be_running
      expect(Buddy::Timers.live_for(user)).to include(timer)
      expect(said.last.body).to include("Rotate Laundry")
      expect(spec["key"]).to eq("laundry")
      expect(spec["item"]).to eq("Fold Laundry")
      expect(spec["list"]).to eq("TODO")
      expect(spec["round"]).to eq(1)
    end
  end

  # The whole reason `key` exists. The button on the wall has no idea whether a
  # timer is already running.
  describe "pressing the button again" do
    it "restarts rather than stacking a second countdown" do
      first = start!
      travel_to(20.minutes.from_now) do
        second = start!

        expect(Buddy::Timers.live_for(user).length).to eq(1)
        expect(first.reload.archived_at).to be_present
        expect(second.remaining_ms).to be_within(5_000).of(4_500_000)
      end
    end

    it "counts the round up" do
      start!
      second = start!

      expect(described_class.spec_for(second)["round"]).to eq(2)
    end

    # A second press is the same as tapping "Rotated".
    it "answers a question already on screen" do
      described_class.on_fired(start!, convo)
      asked = card

      start!

      expect(asked.reload).to be_decided
      expect(asked.decision["value"]).to eq(described_class::AGAIN)
    end

    # Silencing the alarm is a tap anywhere on the page, and that CONFIRMS the
    # timer - which clears `started_at` and drops it out of `live_for` while the
    # question is still up. Reading the round off the timer alone would make
    # every round shushed that way read as the first one.
    it "keeps counting rounds when the ring was only silenced" do
      timer = start!
      described_class.on_fired(timer, convo)
      timer.confirm!

      expect(described_class.live_timer(user, "laundry")).to be_nil
      expect(described_class.spec_for(start!)["round"]).to eq(2)
    end
  end

  describe "on a board" do
    it "stays on the board it was pressed on when it goes round again" do
      first = described_class.start!(
        user:         user,
        key:          "laundry",
        label:        "Rotate Laundry",
        seconds:      4500,
        conversation: convo,
        place:        { Buddy::Timers::BOARD => 42 },
      )
      again = start!

      expect(Buddy::Timers.board_id(first)).to eq(42)
      expect(Buddy::Timers.board_id(again)).to eq(42)
    end
  end

  describe "the fire" do
    it "asks with the three answers on screen, naming the follow-up on Done, and pushes", :aggregate_failures do
      described_class.on_fired(start!, convo)

      expect(card.buttons.pluck("value")).to eq(%w[again done skip])
      expect(card.buttons.first["label"]).to eq("Rotated")
      expect(card.multi_select).to be(false)
      expect(card.buttons[1]["description"]).to include("Fold Laundry", "TODO")
      expect(WebPushNotifications).to have_received(:send_to_byte).with(
        hash_including(title: "Rotate Laundry"),
      )
    end

    it "says nothing about a follow-up when there isn't one" do
      described_class.on_fired(start!(item: nil, list: nil), convo)

      expect(card.buttons[1]).not_to have_key("description")
    end

    # The noise is the point: this is a countdown they set, not a wait.
    it "leaves the timer ringing" do
      timer = start!
      timer.fire_and_maybe_repeat!

      expect(timer.reload.fired_at).to be_present
      expect(timer.confirmed_at).to be_nil
    end

    it "leaves an ordinary timer alone" do
      plain = Buddy::Timers.create!(user: user, seconds: 60, label: "Pasta", conversation: convo)

      expect(described_class.rotation?(plain)).to be(false)
      expect { described_class.on_fired(plain, convo) }.not_to(change(ByteAction, :count))
    end

    # Swiping the chip away, `cancel_timer`, the tool - all of them land in
    # Buddy::Timers.stop!. Taking the countdown and leaving the question is a
    # loop somebody thinks they switched off, still offering another round.
    it "closes the question when the countdown is cancelled instead of answered" do
      timer = start!
      described_class.on_fired(timer, convo)
      asked = card

      Buddy::Timers.stop!(timer)

      expect(asked.reload).to be_decided
      expect(asked.decision["value"]).to eq(described_class::SKIP)
    end
  end

  describe "answering it" do
    before { described_class.on_fired(start!, convo) }

    it "Rotated starts the next round" do
      expect { tap!(card, described_class::AGAIN) }.to change { described_class.spec_for(described_class.live_timer(user, "laundry"))["round"] }.from(1).to(2)

      expect(described_class.live_timer(user, "laundry")).to be_running
    end

    it "Done leaves the follow-up on the list and stops the loop" do
      FactoryBot.create(:list, name: "TODO", user: user)
      tap!(card, described_class::DONE)

      list = List.by_name_for_user("TODO", user)
      expect(list.list_items.map(&:name)).to include("Fold Laundry")
      expect(described_class.live_timer(user, "laundry")).to be_nil
    end

    # Answering the question IS the acknowledgement — otherwise the same thing
    # has to be dismissed twice, once on the card and once on the ringing chip.
    it "Skip clears the ringing chip and leaves nothing behind" do
      expect { tap!(card, described_class::SKIP) }.not_to(change(ListItem, :count))

      expect(described_class.live_timer(user, "laundry")).to be_nil
    end

    # The escape hatch: anything else the round should set off stays in Jil,
    # where it can change without a deploy.
    it "tells Jil which way it went" do
      tap!(card, described_class::DONE)

      expect(::Jil).to have_received(:trigger).with(
        user, described_class::TRIGGER_SCOPE,
        hash_including(key: "laundry", choice: "done", round: 1), auth: :trigger
      )
    end
  end

  # `Buddy.rotate` in a task is one door; this tool is the other.
  describe "the set_rotation tool" do
    let(:ctx)  { Buddy::ToolContext.new(user, conversation: convo) }
    let(:tool) { Buddy::Tools[:set_rotation] }

    # The real path: Buddy::GPT::Turn resolves through `confirm`, then
    # ProposalBuilder executes with the resolved key folded into the payload.
    def ask(payload)
      resolved = tool[:confirm].call(payload, ctx)[:resolved]
      Buddy::Tools.dispatch(tool, payload.merge(resolved), ctx)
    end

    it "starts the loop and says what it will leave behind" do
      result = ask(
        label: "Rotate the laundry", minutes: 75,
        again_label: "Rotated", done_item: "Fold Laundry", done_list: "TODO"
      )

      expect(result[:ok]).to be(true)
      timer = Timer.find(result[:data][:timer_id])
      expect(timer.duration_ms).to eq(75 * 60 * 1000)
      expect(described_class.spec_for(timer)).to include("again" => "Rotated", "item" => "Fold Laundry", "list" => "TODO")
    end

    it "works with no follow-up at all" do
      result = ask(label: "Check the smoker", minutes: 45)

      expect(result[:ok]).to be(true)
      expect(described_class.spec_for(Timer.find(result[:data][:timer_id]))).not_to have_key("item")
    end

    # An item with nowhere to go is a follow-up that silently never lands.
    it "refuses a done_item with no list" do
      expect {
        tool[:confirm].call({ label: "Laundry", minutes: 75, done_item: "Fold Laundry" }, ctx)
      }.to raise_error(/needs a list/)
    end

    it "refuses a loop with no length" do
      expect { tool[:confirm].call({ label: "Laundry" }, ctx) }.to raise_error(/needs a length/)
    end

    # Said out loud instead of tapped, in other words: it has to reach the loop
    # already going round, keeping the follow-up the restart didn't mention.
    it "restarts the loop already going for that thing, keeping its follow-up", :aggregate_failures do
      start!

      result = ask(label: "laundry", minutes: 75)

      expect(Buddy::Timers.live_for(user).length).to eq(1)
      expect(result[:data][:round]).to eq(2)
      expect(described_class.spec_for(described_class.live_timer(user, "laundry"))["item"]).to eq("Fold Laundry")
    end
  end
end

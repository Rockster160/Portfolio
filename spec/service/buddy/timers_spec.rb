require "rails_helper"

RSpec.describe Buddy::Timers do
  let(:user) { create(:user) }

  # Buddy::Timers.create! starts the countdown, which schedules a fire job. The
  # suite runs Sidekiq inline by default, so without fake! the fire worker would
  # run immediately. fake! keeps the scheduled job queued instead.
  around { |ex| Sidekiq::Testing.fake! { ex.run } }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    TimerFireWorker.clear
  end

  describe ".page_for" do
    it "creates a single hidden Buddy page and reuses it" do
      page = described_class.page_for(user)
      expect(page.slug).to eq("buddy")
      expect(described_class.page_for(user)).to eq(page)
      expect(user.timer_pages.where(slug: "buddy").count).to eq(1)
    end
  end

  describe ".create!" do
    it "starts a countdown on the Buddy page and broadcasts :created" do
      Sidekiq::Testing.fake! {
        TimerFireWorker.clear
        timer = described_class.create!(user: user, seconds: 300, label: "Pasta")

        expect(timer.countdown?).to be(true)
        expect(timer.duration_ms).to eq(300_000)
        expect(timer.name).to eq("Pasta")
        expect(timer.timer_page).to eq(described_class.page_for(user))
        expect(timer.running?).to be(true)
        expect(TimerFireWorker.jobs.size).to eq(1)
        expect(MonitorChannel).to have_received(:broadcast_to).with(
          user, hash_including(data: hash_including(reason: :created))
        )
      }
    end

    it "clamps absurd durations and tolerates a blank label" do
      timer = described_class.create!(user: user, seconds: 10_000_000, label: nil)
      expect(timer.duration_ms).to eq(described_class::MAX_SECONDS * 1000)
      expect(timer.name).to eq("")
    end

    it "anchors the countdown to the person's last sent message, not now" do
      convo = user.byte_conversations.create!(mode: :buddy)
      sent_at = 40.seconds.ago
      convo.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: "timer 3m", created_at: sent_at)

      timer = described_class.create!(user: user, seconds: 180, conversation: convo)

      # end_at = sent_at + 180s, so remaining is ~140s, not the full 180.
      expect(timer.end_at).to be_within(2.seconds).of(sent_at + 180.seconds)
      expect(timer.remaining_ms).to be < 180_000
    end

    # Prod: "timer for 5s" announced itself set and expired in the same breath.
    # The turn that created it took a few seconds, and anchoring to the request
    # handed the countdown back already spent. Fine at three minutes, fatal at
    # five seconds - so the back-date is capped as a FRACTION of the countdown.
    it "does not let the back-date eat a short countdown" do
      convo = user.byte_conversations.create!(mode: :buddy)
      convo.byte_messages.create!(
        user: user, direction: :outbound, state: :sent, body: "timer for 5s", created_at: 8.seconds.ago,
      )

      timer = described_class.create!(user: user, seconds: 5, conversation: convo)

      # At most a quarter of 5s may be given back, so >= ~3.75s must remain.
      expect(timer.remaining_ms).to be > 3_500
      expect(timer.end_at).to be > Time.current
    end

    it "still back-dates a long countdown by the full turn latency" do
      convo = user.byte_conversations.create!(mode: :buddy)
      sent_at = 20.seconds.ago
      convo.byte_messages.create!(
        user: user, direction: :outbound, state: :sent, body: "timer 10m", created_at: sent_at,
      )

      timer = described_class.create!(user: user, seconds: 600, conversation: convo)

      expect(timer.end_at).to be_within(2.seconds).of(sent_at + 600.seconds)
    end

    it "leaves no timer and raises when the fire can't be scheduled" do
      allow(TimerFireWorker).to receive(:perform_at).and_raise(StandardError, "redis down")

      expect {
        described_class.create!(user: user, seconds: 120)
      }.to raise_error(StandardError)
      expect(user.timers.where(kind: :countdown).count).to eq(0)
    end

    it "falls back to now when the last send is stale or absent" do
      convo = user.byte_conversations.create!(mode: :buddy)
      convo.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: "old", created_at: 3.hours.ago)

      timer = described_class.create!(user: user, seconds: 120, conversation: convo)
      expect(timer.remaining_ms).to be_within(2000).of(120_000)
    end
  end

  describe ".live_for / .buddy_timer?" do
    it "returns only live Buddy-page timers and identifies them" do
      buddy_timer = described_class.create!(user: user, seconds: 120)
      other_page = user.timer_pages.create!(slug: "work", name: "Work")
      board_timer = user.timers.create!(kind: :countdown, duration_ms: 60_000, timer_page: other_page)

      ids = described_class.live_for(user).map(&:id)
      expect(ids).to include(buddy_timer.id)
      expect(ids).not_to include(board_timer.id)

      expect(described_class.buddy_timer?(user, buddy_timer)).to be(true)
      expect(described_class.buddy_timer?(user, board_timer)).to be(false)
    end

    it "excludes finished / never-started timers so they don't resurrect on reload" do
      page = described_class.page_for(user)
      running = described_class.create!(user: user, seconds: 120)
      confirmed = described_class.create!(user: user, seconds: 120)
      confirmed.confirm! # acknowledged → not archived, but should NOT come back
      never_started = user.timers.create!(kind: :countdown, duration_ms: 60_000, timer_page: page)

      ids = described_class.live_for(user).map(&:id)
      expect(ids).to eq([running.id])
      expect(ids).not_to include(confirmed.id, never_started.id)
    end
  end

  describe ".on_fired" do
    before { allow(WebPushNotifications).to receive(:send_to_byte) }

    it "posts a Buddy message into the conversation when a buddy timer fires" do
      convo = Buddy::CompanionRelay.conversation_for(user)
      timer = described_class.create!(user: user, seconds: 60, label: "Pasta")

      expect { described_class.on_fired(timer) }.to(
        change { convo.byte_messages.where(direction: :inbound).count }.by(1),
      )

      msg = convo.byte_messages.where(direction: :inbound).order(:created_at).last
      expect(msg.body).to include("Pasta").and(include("Time's up"))
      expect(msg.metadata["source"]).to eq("timer")
      expect(WebPushNotifications).to have_received(:send_to_byte)
    end

    it "does nothing for a timer that isn't Buddy's" do
      other_page = user.timer_pages.create!(slug: "work", name: "Work")
      board = user.timers.create!(kind: :countdown, duration_ms: 60_000, timer_page: other_page)

      expect { described_class.on_fired(board) }.not_to(change(ByteMessage, :count))
    end
  end

  describe ".humanize_seconds" do
    it "phrases durations" do
      expect(described_class.humanize_seconds(45)).to eq("45 sec")
      expect(described_class.humanize_seconds(300)).to eq("5 min")
      expect(described_class.humanize_seconds(90)).to eq("1 min 30 sec")
    end
  end

  describe "set_timer tool" do
    it "is registered as an auto tool and creates a timer on execute" do
      tool = Buddy::Tools[:set_timer]
      expect(tool[:auto]).to be(true)

      convo = user.byte_conversations.create!(mode: :buddy)
      ctx = Buddy::ToolContext.new(user, conversation: convo)
      result = Buddy::Tools.dispatch(tool, { seconds: 60, label: "Tea" }, ctx)

      expect(result[:ok]).to be(true)
      expect(Timer.find(result[:data][:timer_id]).name).to eq("Tea")
      expect(tool[:receipt].call(result[:data], ctx)).to include("1 min timer for Tea")
    end
  end
end

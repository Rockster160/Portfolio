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

  # Serving a plain timer request from Rails skips a model round trip that costs
  # several seconds and might not call the tool at all. The whole risk is
  # hijacking a message that meant something else, so the negatives below matter
  # more than the positives.
  describe ".parse_request" do
    def parse(text) = described_class.parse_request(text)

    it "reads a bare duration" do
      expect(parse("5m")).to eq(seconds: 300, label: nil)
      expect(parse("90s")).to eq(seconds: 90, label: nil)
      expect(parse("2h")).to eq(seconds: 7200, label: nil)
      expect(parse("45 min")).to eq(seconds: 2700, label: nil)
    end

    it "reads a duration with a label" do
      expect(parse("5m pasta")).to eq(seconds: 300, label: "pasta")
      expect(parse("10 min tea")).to eq(seconds: 600, label: "tea")
    end

    it "adds compound durations up" do
      expect(parse("1h30m")).to eq(seconds: 5400, label: nil)
      expect(parse("1h 30m")).to eq(seconds: 5400, label: nil)
    end

    it "reads the explicit phrasings people actually type" do
      expect(parse("timer for 5s")).to eq(seconds: 5, label: nil)
      expect(parse("Set a timer for 1m")).to eq(seconds: 60, label: nil)
      expect(parse("set a timer for 10 minutes")).to eq(seconds: 600, label: nil)
      expect(parse("start a timer for 20m laundry")).to eq(seconds: 1200, label: "laundry")
      expect(parse("timer 10m")).to eq(seconds: 600, label: nil)
    end

    # "timer" is the word for the thing, not a name for it. A 10-minute timer
    # called "timer" (or worse, "timer for pasta") is nobody's idea of a label.
    it "never turns the word timer into the timer's name" do
      expect(parse("10m timer")).to eq(seconds: 600, label: nil)
      expect(parse("10 min timer")).to eq(seconds: 600, label: nil)
      expect(parse("10m timer for pasta")).to eq(seconds: 600, label: "pasta")
      expect(parse("5m timer for the pasta")).to eq(seconds: 300, label: "pasta")
    end

    it "drops the article people put in front of a label" do
      expect(parse("20m for the laundry")).to eq(seconds: 1200, label: "laundry")
    end

    # Every one of these leads with a duration and is NOT a countdown request.
    # Turning them into timers would swallow a chore completion, which is the
    # thing the person most wants recorded.
    it "leaves a reported duration alone" do
      expect(parse("20 minutes of stretching")).to be_nil
      expect(parse("5 min walk done")).to be_nil
      expect(parse("2 hours of sleep")).to be_nil
      expect(parse("30m left on the roast")).to be_nil
      expect(parse("15 min ago")).to be_nil
    end

    it "leaves anything that isn't led by a duration alone" do
      expect(parse("I did 20 minutes of stretching")).to be_nil
      expect(parse("remind me in 5 minutes to call mom")).to be_nil
      expect(parse("how long is 5m")).to be_nil
      expect(parse("hey")).to be_nil
      expect(parse("")).to be_nil
    end

    it "leaves a question alone even when it starts with a duration" do
      expect(parse("5m?")).to be_nil
    end

    # A long leading duration is far likelier to be narration than a countdown,
    # and the agent can still set it via the tool.
    it "hands an implausibly long countdown to the model instead" do
      expect(parse("8 hours sleep")).to be_nil
      expect(parse("8h")).to be_nil
    end

    it "hands a wordy message to the model instead" do
      expect(parse("5m pasta and also start the dishwasher please")).to be_nil
    end

    # "2 hours early please Suki" became a two-hour countdown named "early
    # please Suki" - it cleared every check because the leftover happened to be
    # exactly three words. Nobody names a timer by asking for one.
    it "leaves a duration wrapped in a request to the companion alone" do
      expect(parse("2 hours early please Suki")).to be_nil
      expect(parse("2 hours please")).to be_nil
      expect(parse("10 min remind me")).to be_nil
      expect(parse("5 min let me know")).to be_nil
    end

    # ...but saying "timer" outright is unambiguous however politely it's asked.
    it "still takes an explicit timer request with please in it" do
      expect(parse("timer for 5m please")).to eq(seconds: 300, label: nil)
    end
  end

  # The fast path answers nothing: it posts a chip and returns without a turn.
  # Firing it on a reply to Buddy's own question leaves the question hanging,
  # and the person has to say the whole thing again.
  describe ".parse_request in a conversation" do
    let(:conversation) { user.byte_conversations.create!(mode: :buddy, name: "Buddy") }

    def buddy_says(body, kind: :buddy)
      conversation.byte_messages.create!(
        user: user, direction: :inbound, state: :delivered,
        body: body, metadata: { "kind" => kind.to_s }, delivered_at: Time.current
      )
    end

    def parse(text) = described_class.parse_request(text, conversation: conversation)

    it "declines a bare duration answering a question Buddy just asked" do
      buddy_says("Ja, I can do that! How early do you want the nudge, before 6 PM?")

      expect(parse("2 hours")).to be_nil
    end

    # Suki's persona terminates nearly everything in "!", so a question from her
    # routinely carries no question mark at all.
    it "reads a question that ends in an exclamation mark as a question" do
      buddy_says("Absolutely! What do you want on it!")

      expect(parse("20 min")).to be_nil
    end

    it "still fast-paths after an ordinary Buddy reply" do
      buddy_says("Popped that on your list!")

      expect(parse("5m pasta")).to eq(seconds: 300, label: "pasta")
    end

    # A receipt chip isn't Buddy asking anything, and one lands after most
    # tool calls - treating it as prose would disable the fast path constantly.
    it "ignores receipt chips when deciding" do
      buddy_says("Suki set a 5 min timer for pasta ⏲", kind: :buddy_activity)

      expect(parse("10m tea")).to eq(seconds: 600, label: "tea")
    end

    it "takes an explicit timer request even mid-question" do
      buddy_says("How long do you want it for?")

      expect(parse("timer for 10m")).to eq(seconds: 600, label: nil)
    end

    it "fast-paths in an empty thread" do
      expect(parse("5m")).to eq(seconds: 300, label: nil)
    end
  end

  describe ".quick_set!" do
    let(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy") }

    it "starts the timer and posts the same chip the tool path posts" do
      chip = described_class.quick_set!(user, convo, seconds: 300, label: "pasta")

      expect(chip.body).to eq("Byte set a 5 min timer for pasta ⏲")
      expect(chip.metadata["kind"]).to eq("buddy_activity")
      expect(chip.metadata["tool_name"]).to eq("set_timer")
      expect(user.timers.where(kind: :countdown).count).to eq(1)
      expect(described_class.live_for(user).first.duration_ms).to eq(300_000)
    end

    it "returns nil rather than raising when the timer can't start" do
      allow(TimerFireWorker).to receive(:perform_at).and_raise(StandardError, "redis down")
      allow(Buddy::Errors).to receive(:report)

      expect(described_class.quick_set!(user, convo, seconds: 60)).to be_nil
    end

    # Nobody composes a fast-pathed timer, so nothing answered the person -
    # and every other receipt chip is kept out of history. The transcript
    # showed the request with nothing after it, so the next vague message got
    # read as being about it: "set a timer for 50 minutes to rotate laundry" at
    # 10:41, "Okay! What next?" at 11:30, and the reply was "Timer's set for 50
    # minutes, and it's labeled rotate laundry" plus a second 50-minute timer.
    it "leaves a trace the model can see, so the next turn knows it happened" do
      convo.byte_messages.create!(
        user: user, direction: :outbound, state: :sent, body: "set a timer for 50 minutes to rotate laundry",
      )
      described_class.quick_set!(user, convo, seconds: 3000, label: "rotate laundry")
      last = convo.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: "Okay! What next?")

      turns = Buddy::GPT::History.build(convo.reload, upto: last)

      expect(turns.pluck(:role)).to eq(%i[user assistant user])
      expect(turns[1][:content]).to include("50 min timer")
    end

    it "still keeps ordinary receipt chips out, since a reply already covers those" do
      convo.byte_messages.create!(
        user:      user,
        direction: :inbound,
        state:     :delivered,
        body:      "Byte will send you a reminder at 5pm",
        metadata:  { "kind" => "buddy_activity", "tool_name" => "schedule_reminder", "ok" => true },
      )
      last = convo.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: "thanks")

      expect(Buddy::GPT::History.build(convo.reload, upto: last).pluck(:role)).to eq([:user])
    end
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

    # The back-date is NOT clamped to protect short countdowns. A "5 minute
    # timer" ends five minutes after it was asked for, and trimming that to keep
    # a short one alive would make every timer end at a slightly different offset
    # than requested. A short timer landing already spent is honest; the answer
    # is to not spend seconds in a model round trip (see the fast path).
    it "honours the request time even when that leaves the countdown spent" do
      convo = user.byte_conversations.create!(mode: :buddy)
      convo.byte_messages.create!(
        user: user, direction: :outbound, state: :sent, body: "timer for 5s", created_at: 8.seconds.ago,
      )

      timer = described_class.create!(user: user, seconds: 5, conversation: convo)

      expect(timer.end_at).to be < Time.current
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

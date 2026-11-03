require "rails_helper"

RSpec.describe Buddy::Timers do
  describe "timers" do
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

      it "reads durations, labels and explicit timer phrasings", :aggregate_failures do
        [
          ["5m", 300, nil],
          ["90s", 90, nil],
          ["2h", 7200, nil],
          ["45 min", 2700, nil],
          ["5m pasta", 300, "pasta"],
          ["10 min tea", 600, "tea"],
          ["1h30m", 5400, nil],
          ["1h 30m", 5400, nil],
          ["timer for 5s", 5, nil],
          ["Set a timer for 1m", 60, nil],
          ["set a timer for 10 minutes", 600, nil],
          ["start a timer for 20m laundry", 1200, "laundry"],
          ["timer 10m", 600, nil],
          # "timer" is the word for the thing, never its name.
          ["10m timer", 600, nil],
          ["10 min timer", 600, nil],
          ["10m timer for pasta", 600, "pasta"],
          ["5m timer for the pasta", 300, "pasta"],
          ["20m for the laundry", 1200, "laundry"],
          # Saying "timer" outright is unambiguous however politely it's asked.
          ["timer for 5m please", 300, nil],
        ].each { |text, seconds, label|
          expect(parse(text)).to eq({ seconds: seconds, label: label }), text
        }
      end

      # Hijacking a message that meant something else is the whole risk: a
      # reported duration would swallow a chore completion.
      it "leaves anything that isn't a countdown request to the model", :aggregate_failures do
        [
          "20 minutes of stretching",
          "5 min walk done",
          "2 hours of sleep",
          "30m left on the roast",
          "15 min ago",
          "I did 20 minutes of stretching",
          "remind me in 5 minutes to call mom",
          "how long is 5m",
          "hey",
          "",
          "5m?",
          # Implausibly long, so likelier narration than a countdown.
          "8 hours sleep",
          "8h",
          "5m pasta and also start the dishwasher please",
          # A duration wrapped in a request to the companion.
          "2 hours early please Suki",
          "2 hours please",
          "10 min remind me",
          "5 min let me know",
        ].each { |text| expect(parse(text)).to be_nil, text.inspect }
      end
    end

    # The fast path answers nothing: it posts a chip and returns without a turn.
    # Firing it on a reply to Buddy's own question leaves the question hanging,
    # and the person has to say the whole thing again.
    describe ".parse_request in a conversation" do
      let(:conversation) { user.byte_conversations.create!(mode: :buddy, name: "Buddy") }

      def buddy_says(body, kind: :buddy, **meta)
        conversation.byte_messages.create!(
          user: user, direction: :inbound, state: :delivered,
          body: body, metadata: { "kind" => kind.to_s }.merge(meta.stringify_keys),
          delivered_at: Time.current
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

      # A card is answered by tapping it, not by typing at it.
      it "ignores a form card, which is not a question anybody types into" do
        buddy_says("Who did: Puppy Down?", kind: :buddy_reply, source: "form")

        expect(parse("12m")).to eq(seconds: 720, label: nil)
      end

      # The half that must keep working: a real question is prose, with no source.
      it "still declines a bare duration after a real question" do
        buddy_says("Who did: Puppy Down?", kind: :buddy_reply, source: "form")
        buddy_says("How long do you want it for?")

        expect(parse("12m")).to be_nil
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

      # Nobody composes a fast-pathed timer, so its chip is the only trace in
      # history that the request was answered.
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
        expect(page.slug).to eq("__buddy")
        expect(described_class.page_for(user)).to eq(page)
        expect(user.timer_pages.where(slug: Buddy::Timers::PAGE_SLUG).count).to eq(1)
      end

      it "leaves a page of the person's own called buddy alone" do
        theirs = user.timer_pages.create!(name: "Buddy", slug: "buddy")
        expect(described_class.page_for(user)).not_to eq(theirs)
      end
    end

    describe ".archive_finished!" do
      it "archives acknowledged timers a day old, keeping running and recent ones" do
        page    = described_class.page_for(user)
        old     = create(:timer, user: user, timer_page: page, updated_at: 2.days.ago)
        recent  = create(:timer, user: user, timer_page: page)
        running = create(:timer, user: user, timer_page: page, started_at: 3.days.ago, updated_at: 2.days.ago)

        described_class.archive_finished!(page)

        expect(old.reload.archived_at).to be_present
        expect(recent.reload.archived_at).to be_nil
        expect(running.reload.archived_at).to be_nil
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

      it "anchors an :message countdown to the person's last sent message, not now" do
        convo = user.byte_conversations.create!(mode: :buddy)
        sent_at = 40.seconds.ago
        convo.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: "timer 3m", created_at: sent_at)

        timer = described_class.create!(user: user, seconds: 180, conversation: convo, anchor: :message)

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

        timer = described_class.create!(user: user, seconds: 5, conversation: convo, anchor: :message)

        expect(timer.end_at).to be < Time.current
      end

      # Resuming a zero-remaining pause would reschedule a fire in the past and
      # re-arm at zero forever.
      it "will not pause a countdown that has nothing left" do
        timer = described_class.create!(user: user, seconds: 60)
        timer.update_columns(started_at: 2.minutes.ago, end_at: 1.minute.ago)

        timer.pause!

        expect(timer.reload).not_to be_paused
        expect(timer.paused_remaining_ms).to be_nil
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
      it "creates a timer on execute" do
        tool = Buddy::Tools[:set_timer]

        convo = user.byte_conversations.create!(mode: :buddy)
        ctx = Buddy::ToolContext.new(user, conversation: convo)
        result = Buddy::Tools.dispatch(tool, { seconds: 60, label: "Tea" }, ctx)

        expect(result[:ok]).to be(true)
        expect(Timer.find(result[:data][:timer_id]).name).to eq("Tea")
      end

      # The tool does the clock subtraction, not the model.
      it "runs until a clock time, counted from now" do
        tool = Buddy::Tools[:set_timer]
        zone = Time.find_zone(user.timezone)
        travel_to(zone.local(2026, 10, 23, 15, 14, 0)) {
          ctx = Buddy::ToolContext.new(user, conversation: user.byte_conversations.create!(mode: :buddy))
          payload = { ends_at: "2026-10-23T17:25:00" }
          payload = payload.merge(tool[:confirm].call(payload, ctx)[:resolved])
          result = Buddy::Tools.dispatch(tool, JSON.parse(payload.to_json).symbolize_keys, ctx)

          expect(result[:data][:seconds]).to eq(131 * 60)
          expect(Timer.find(result[:data][:timer_id]).end_at).to eq(zone.local(2026, 10, 23, 17, 25, 0))
        }
      end

      it "refuses a clock time that has already gone" do
        ctx = Buddy::ToolContext.new(user)
        expect {
          Buddy::Tools[:set_timer][:confirm].call({ ends_at: 5.minutes.ago.iso8601 }, ctx)
        }.to raise_error(/already passed/)
      end
    end

    # A board shows only the timers attached to it; the chat shows them all.
    describe "boards" do
      let(:chat)  { user.byte_conversations.create!(mode: :buddy) }
      let(:board) { user.byte_conversations.create!(mode: :buddy, name: "Kitchen", metadata: { "board" => true }) }
      let(:other) { user.byte_conversations.create!(mode: :buddy, name: "Office", metadata: { "board" => true }) }

      it "attaches a timer started from a board to that board, and one from the chat to none" do
        on_board = described_class.create!(user: user, seconds: 60, conversation: board)
        in_chat  = described_class.create!(user: user, seconds: 60, conversation: chat)

        expect(described_class.board_id(on_board)).to eq(board.id)
        expect(described_class.board_id(in_chat)).to be_nil
        expect(described_class.live_for_board(board)).to eq([on_board])
        expect(described_class.live_for_board(other)).to be_empty
        expect(described_class.live_for(user)).to contain_exactly(on_board, in_chat)
      end

      it "lets set_timer name a board from the chat" do
        board
        tool    = Buddy::Tools[:set_timer]
        ctx     = Buddy::ToolContext.new(user, conversation: chat)
        payload = { minutes: 5, board: "kitchen board" }
        resolved = tool[:confirm].call(payload, ctx)[:resolved]
        result = Buddy::Tools.dispatch(tool, payload.merge(resolved), ctx)

        expect(described_class.board_id(Timer.find(result[:data][:timer_id]))).to eq(board.id)
      end

      it "shows a timer on every board watching one of its groups" do
        board.update!(chore_tags: ["Home"])
        grouped = described_class.create!(user: user, seconds: 60, place: described_class.placement(chat, groups: "home"))

        expect(described_class.groups(grouped)).to eq(["home"])
        expect(described_class.live_for_board(board)).to eq([grouped])
        expect(described_class.live_for_board(other)).to be_empty
      end

      it "shows every timer on an All board, until its timers are switched off" do
        board.update!(chore_tags: ["All"])
        in_chat = described_class.create!(user: user, seconds: 60, conversation: chat)

        expect(described_class.live_for_board(board)).to eq([in_chat])
        expect(described_class.live_for_board(other)).to be_empty

        board.update!(metadata: board.metadata.merge("timer_alerts" => false))
        expect(described_class.live_for_board(board)).to be_empty
      end

      it "leaves a regular timer off an All board" do
        board.update!(chore_tags: ["All"])
        user.timers.create!(kind: :countdown, duration_ms: 60_000, started_at: Time.current)

        expect(described_class.live_for_board(board)).to be_empty
      end

      describe "in a household" do
        let(:house) { create(:chore_household) }
        let!(:housemate) { create(:user, chore_household_id: house.id) }
        let(:theirs) {
          housemate.byte_conversations.create!(
            mode: :buddy, name: "Living Room", metadata: { "board" => true, "chore_tags" => ["Home"] },
          )
        }

        before { user.update!(chore_household_id: house.id) }

        it "puts a timer on a housemate's board once it's shared" do
          mine = described_class.create!(user: user, seconds: 60, place: described_class.placement(chat, groups: "Home"))
          expect(described_class.live_for_board(theirs)).to be_empty

          theirs.update!(metadata: theirs.metadata.merge("shared" => true))
          expect(described_class.live_for_board(theirs)).to eq([mine])
        end

        it "lets set_timer name a housemate's shared board" do
          theirs.update!(metadata: theirs.metadata.merge("shared" => true))
          ctx = Buddy::ToolContext.new(user, conversation: chat)

          resolved = Buddy::Tools[:set_timer][:confirm].call({ minutes: 5, board: "Living Room" }, ctx)[:resolved]
          expect(resolved[:board_id]).to eq(theirs.id)
        end

        it "tells the household about a placed timer, and only its owner about one in the chat" do
          placed = described_class.create!(user: user, seconds: 60, place: described_class.placement(chat, groups: "Home"))
          alone  = described_class.create!(user: user, seconds: 60, conversation: chat)

          expect(described_class.audience(placed)).to include(user, housemate)
          expect(described_class.audience(alone)).to eq([user])
        end

        it "puts every household timer on a shared All board, and tells the household" do
          alone = described_class.create!(user: user, seconds: 60, conversation: chat)
          theirs.update!(metadata: theirs.metadata.merge("chore_tags" => ["All"]))
          expect(described_class.live_for_board(theirs)).to be_empty
          expect(described_class.audience(alone)).to eq([user])

          theirs.update!(metadata: theirs.metadata.merge("shared" => true))
          expect(described_class.live_for_board(theirs)).to eq([alone])
          expect(described_class.audience(alone)).to include(user, housemate)
          expect(described_class.reachable(housemate, alone.id)).to eq(alone)

          theirs.update!(metadata: theirs.metadata.merge("timer_alerts" => false))
          expect(described_class.audience(alone)).to eq([user])
          expect(described_class.reachable(housemate, alone.id)).to be_nil
        end

        it "lets a housemate reach a placed timer from the board, but not one in the chat" do
          placed = described_class.create!(user: user, seconds: 60, place: described_class.placement(chat, groups: "Home"))
          alone  = described_class.create!(user: user, seconds: 60, conversation: chat)

          expect(described_class.reachable(housemate, placed.id)).to eq(placed)
          expect(described_class.reachable(housemate, alone.id)).to be_nil
          expect(described_class.reachable(user, alone.id)).to eq(alone)
        end
      end

      it "says which boards there are when the name matches none" do
        board
        ctx = Buddy::ToolContext.new(user, conversation: chat)

        expect { Buddy::Tools[:set_timer][:confirm].call({ minutes: 5, board: "Garage" }, ctx) }
          .to raise_error(/no board called "Garage".*Kitchen/)
      end
    end

    describe "cancel_timer tool" do
      let(:convo) { user.byte_conversations.create!(mode: :buddy) }
      let(:ctx)   { Buddy::ToolContext.new(user, conversation: convo) }
      let(:tool)  { Buddy::Tools[:cancel_timer] }

      # The real path: Buddy::GPT::Turn resolves the call through `confirm`, then
      # ProposalBuilder executes with the resolved ids folded into the payload.
      def cancel(match)
        payload  = { match: match }
        resolved = tool[:confirm].call(payload, ctx)[:resolved]
        Buddy::Tools.dispatch(tool, payload.merge(resolved), ctx)
      end

      it "stops a timer by label and takes it off the hero" do
        described_class.create!(user: user, seconds: 300, label: "pasta")

        result = cancel("pasta")

        expect(result[:ok]).to be(true)
        expect(described_class.live_for(user)).to be_empty
      end

      it "stops every one of them on 'all'" do
        described_class.create!(user: user, seconds: 300, label: "pasta")
        described_class.create!(user: user, seconds: 600, label: "tea")

        result = cancel("all")

        expect(result[:data][:stopped]).to eq(2)
        expect(described_class.live_for(user)).to be_empty
      end

      # The commonest timer is "5m" with no label at all, so matching on name
      # would miss exactly the one they're looking at.
      it "stops the only running timer even when they name it something else" do
        described_class.create!(user: user, seconds: 300)

        expect(cancel("the countdown")[:data][:stopped]).to eq(1)
      end

      it "leaves timers on their ordinary board alone" do
        page  = user.timer_pages.create!(slug: "work", name: "Work")
        board = user.timers.create!(kind: :countdown, duration_ms: 60_000, timer_page: page)
        board.start!

        expect { cancel("all") }.to raise_error(/nothing is running/i)
        expect(board.reload.archived_at).to be_nil
      end

      it "says nothing is running rather than claiming it can't reach them" do
        expect { cancel("pasta") }.to raise_error(/nothing is running/i)
      end

      it "reports a name that matches none of them" do
        described_class.create!(user: user, seconds: 300, label: "pasta")
        described_class.create!(user: user, seconds: 600, label: "tea")

        expect { cancel("laundry") }.to raise_error(/no timer matching/i)
      end
    end

    describe "running_timers context" do
      let(:convo) { user.byte_conversations.create!(mode: :buddy) }

      it "shows what's on the clock so Buddy can answer and cancel" do
        described_class.create!(user: user, seconds: 300, label: "pasta")

        row = Buddy::Context.build(user, convo)[:running_timers].first

        expect(row[:label]).to eq("pasta")
        expect(row[:remaining]).to include("left")
      end

      it "is empty rather than absent when nothing is counting" do
        expect(Buddy::Context.build(user, convo)[:running_timers]).to eq([])
      end
    end
  end

  # A watch that starts a COUNTDOWN instead of saying something.
  describe "a timer set by a watch" do
    let(:user) { create(:user) }
    let!(:list_task) {
      Task.create!(
        user: user, name: "Claude List Log", listener: "item:action:added",
        code: "", enabled: true, buddy_enabled: true
      )
    }
    let!(:list) { user.lists.create!(name: "Claude").tap { |l| user.user_lists.create!(list: l) } }
    let!(:convo) { ByteConversation.create!(user: user, mode: :buddy, name: "Buddy", last_message_at: Time.current) }
    let(:msg)    { convo.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "ok") }

    before do
      allow(MonitorChannel).to receive(:broadcast_to)
      Rails.cache.delete("jil:wired_scopes:#{user.id}")
    end

    def run(payload)
      markers = [{ tool_name: :remind_when, payload: payload, span: [0, 0] }]
      Buddy::ProposalBuilder.create(user: user, byte_message: msg, markers: markers)
    end

    def claude_list(**extra)
      {
        text:        "Claude list got something",
        trigger:     "custom",
        listener:    "item:action:added item:list:name:/^Claude$/",
        when_phrase: "when something is added to the Claude list",
        repeat:      true,
        **extra,
      }
    end

    describe "setting one" do
      it "makes a timer watch carrying the countdown length" do
        expect { run(claude_list(timer: 1)) }.to change(BuddyWatch, :count).by(1)

        watch = BuddyWatch.last
        expect(watch.kind).to eq("timer")
        expect(watch).to be_timer
        expect(watch.timer_seconds).to eq(1)
      end

      it "still makes an ordinary reminder watch when no timer is named" do
        run(claude_list)

        expect(BuddyWatch.last.kind).to eq("prompt")
        expect(BuddyWatch.last.timer_seconds).to be_zero
      end

      it "does not both tell someone else and set a timer" do
        create(:user, username: "chelsea")

        run(claude_list(timer: 1, notify: "chelsea"))

        expect(BuddyWatch.count).to eq(0)
      end

      it "caps an absurd countdown at what the timer stack would take anyway" do
        run(claude_list(timer: 9_999_999))

        expect(BuddyWatch.last.timer_seconds).to eq(Buddy::Timers::MAX_SECONDS)
      end
    end

    describe "when it fires" do
      let!(:watch) {
        run(claude_list(timer: 1))
        BuddyWatch.last
      }

      it "starts a countdown named for what the watch was about" do
        expect {
          Buddy::WatchMatcher.fire!(watch)
        }.to change { user.timers.count }.by(1)

        expect(user.timers.order(:id).last).to have_attributes(duration_ms: 1_000, name: "Claude list got something")
      end

      it "keeps firing while the watch repeats" do
        Buddy::WatchMatcher.fire!(watch)
        watch.reload.update!(metadata: watch.metadata.except("last_signature"))

        expect { Buddy::WatchMatcher.fire!(watch) }.to change { user.timers.count }.by(1)
      end

      it "leaves the thread alone — the alarm is the message" do
        said = -> { convo.byte_messages.where("metadata->>'source' = 'watch'").count }

        expect { Buddy::WatchMatcher.fire!(watch) }.not_to change(said, :call)
      end
    end

    # A timer watch and a reminder watch read identically in context otherwise.
    it "says what it does when Buddy looks at what it's watching" do
      run(claude_list(timer: 1))

      listed = Buddy::Context.send(:active_watches, convo)

      expect(listed.first[:does]).to eq("starts a 1 sec timer")
    end
  end
end

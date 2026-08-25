require "rails_helper"

RSpec.describe ByteMessageIntake do
  # One send, one message, however many times the client asks.
  #
  # The client mints a `local_id` per composed message and its outbound queue
  # retries on any uncertain outcome — a dropped response, a PWA backgrounded
  # mid-send, a double-fired tap. queue.js has always documented the other half of
  # that contract as ours: "the server treats a repeat with the same local_id as
  # idempotent." It didn't.
  #
  # Prod 3781/3783: one send, two rows, same local_id and the same client-stamped
  # created_at to the millisecond. Two rows meant two turns, two replies, and
  # "light covers" put on the agenda twice. It had happened once before, in July
  # (1397/1399), and nothing in the thread says which of the pair is real.
  describe "idempotency" do
    let(:user)  { User.me }
    let(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }
    let(:lid)   { "922cfa6d-ba39-43c4-999c-6aad98724c3d" }

    before do
      allow(MonitorChannel).to receive(:broadcast_to)
      allow(BuddyDeliverWorker).to receive(:perform_async)
    end

    def send!(body, local_id: lid, conversation: convo)
      described_class.call(
        user:         user,
        conversation: conversation,
        body:         body,
        metadata:     ({ local_id: local_id } if local_id).to_h,
      )
    end

    it "creates one row when the same send arrives twice" do
      first = send!("Also add light covers")

      expect { send!("Also add light covers") }.not_to change(ByteMessage, :count)
      expect(send!("Also add light covers").id).to eq(first.id)
    end

    # The duplicate turn is what actually cost something: two replies, and the
    # task on the agenda twice.
    it "runs the turn once" do
      send!("Also add light covers")
      send!("Also add light covers")

      expect(BuddyDeliverWorker).to have_received(:perform_async).once
    end

    it "hands back the row the client is waiting for, not nil" do
      first = send!("Also add light covers")
      again = send!("Also add light covers")

      expect(again).to be_a(ByteMessage)
      expect(again.body).to eq(first.body)
    end

    # A retry can carry different text only if something is badly wrong; the id is
    # the identity, and the row that already exists is the one the thread shows.
    it "keeps the first body when a repeat carries different text" do
      first = send!("Also add light covers")

      expect(send!("something else entirely").id).to eq(first.id)
      expect(first.reload.body).to eq("Also add light covers")
    end

    it "leaves genuinely separate sends alone" do
      send!("first thing", local_id: SecureRandom.uuid)

      expect { send!("second thing", local_id: SecureRandom.uuid) }.to change(ByteMessage, :count).by(1)
    end

    # The Mac CLI door (/webhooks/byte/say) doesn't mint one, and two identical
    # messages typed twice on purpose are two messages.
    it "does not dedupe when there's no local_id at all" do
      send!("ok", local_id: nil)

      expect { send!("ok", local_id: nil) }.to change(ByteMessage, :count).by(1)
    end

    # A local_id is only unique within the client that minted it.
    it "scopes the key to the conversation" do
      other = user.byte_conversations.create!(mode: :buddy, name: "Other")
      send!("Also add light covers")

      expect { send!("Also add light covers", conversation: other) }.to change(ByteMessage, :count).by(1)
    end

    # Belt and braces for the case the check at the top can't catch: two requests
    # in flight together, both finding nothing. The index is what settles it, and
    # the send still has to come back as delivered rather than a 500.
    it "survives a race that gets past the check" do
      first = send!("Also add light covers")
      allow_any_instance_of(described_class).to receive(:existing_for_local_id).and_return(nil, first)

      expect { expect(send!("Also add light covers").id).to eq(first.id) }
        .not_to change(ByteMessage, :count)
    end
  end

  # What the SENDER's own bubble says about their message.
  #
  # It used to be posted `pending` and flipped to `sent` by TurnDispatcher, which
  # is when the worker picks it up — so "…" meant "a Sidekiq job hasn't started",
  # and the HTTP response to the send carried that stale snapshot. Whichever of
  # the two routes landed second won, the websocket usually got there first, and
  # the echo then repainted the bubble back to sending. It stayed there: nothing
  # broadcasts that message again. Byte would be mid-reply above a message still
  # showing as pending.
  describe "state" do
    let(:user)  { User.me }
    let(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }

    before do
      allow(MonitorChannel).to receive(:broadcast_to)
      allow(BuddyDeliverWorker).to receive(:perform_async)
    end

    def send!(body)
      described_class.call(user: user, conversation: convo, body: body)
    end

    it "counts as sent the moment the server has it" do
      expect(send!("what's on my agenda?")).to be_sent
    end

    it "still hands the turn to Buddy" do
      message = send!("what's on my agenda?")

      expect(BuddyDeliverWorker).to have_received(:perform_async).with(message.id)
    end

    # The order the client needs: their bubble settles first, and the pet starts
    # thinking after, as its own separate signal.
    it "confirms the message before it says Buddy is thinking" do
      seen = []
      allow(MonitorChannel).to receive(:broadcast_to) { |_u, payload|
        seen << (payload.dig(:data, :kind) == :message ? :message : :other)
      }
      allow(Buddy::ExpressionState).to receive(:transition!) { seen << :thinking }

      send!("hello")

      expect(seen.first).to eq(:message)
      expect(seen).to include(:thinking)
    end

    # The one case where it legitimately isn't going anywhere yet.
    it "says queued instead when Buddy is asleep" do
      allow(Buddy::SleepGuard).to receive(:sleeping?).and_return(true)

      expect(send!("hello")).to be_queued
      expect(BuddyDeliverWorker).not_to have_received(:perform_async)
    end

    describe "the turn that follows" do
      it "leaves an already-sent message alone rather than repainting it" do
        message = send!("hello")
        allow(Buddy::GPT::Turn).to receive(:run!).and_return(true)
        allow(Buddy::Compactor).to receive(:should_compact?).and_return(false)

        expect(MonitorChannel).not_to receive(:broadcast_to)
        Buddy::TurnDispatcher.deliver!(message)
      end

      # BuddyWakeWorker hands a drained message back as `pending`, so the flip
      # still has to happen for that one.
      it "still settles one that came back out of the sleep queue" do
        message = send!("hello")
        message.update!(state: :pending)
        allow(Buddy::GPT::Turn).to receive(:run!).and_return(true)
        allow(Buddy::Compactor).to receive(:should_compact?).and_return(false)

        Buddy::TurnDispatcher.deliver!(message)

        expect(message.reload).to be_sent
      end
    end
  end

  # A "." in front of a message sends it straight to Jarvis, exactly as if it had
  # been said out loud in the room — from any thread, whatever that thread is
  # normally for.
  describe ".jarvis_aside?" do
    let(:user)  { User.me }
    let(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy") }

    before do
      allow(MonitorChannel).to receive(:broadcast_to)
      allow(BuddyDeliverWorker).to receive(:perform_async)
      allow(ByteJarvisWorker).to receive(:perform_async)
    end

    def send!(body, as: user, conversation: convo)
      ByteMessageIntake.call(user: as, conversation: conversation, body: body)
    end

    describe "what a prefix means" do
      it "reads a dot in front of unknown words as Jarvis" do
        expect(ByteMessageIntake).to be_jarvis_aside("  .garage door open")
      end

      # The mobile shortcut survives: the period is closer to the space bar than
      # the slash, which is why it was made an alias in the first place.
      it "leaves the known slash verbs alone" do
        [".today", ".rename Foo", ".compact", ".fork", ".sessions", ".pwd"].each { |body|
          expect(ByteMessageIntake).to be_slash_command(body)
          expect(ByteMessageIntake).not_to be_jarvis_aside(body)
        }
      end

      # An unknown verb after a slash is the Mac's to answer or refuse, and always
      # has been. Only the dot changed meaning.
      it "never reads a slash as Jarvis" do
        expect(ByteMessageIntake).not_to be_jarvis_aside("/garage door open")
        expect(ByteMessageIntake).to be_slash_command("/nonsense")
      end

      it "hands Jarvis the words without the marker" do
        expect(ByteMessageIntake.jarvis_words(" .garage door open ")).to eq("garage door open")
      end
    end

    describe "dispatch" do
      it "sends it to Jarvis instead of Buddy" do
        send!(".garage door open")

        expect(ByteJarvisWorker).to have_received(:perform_async)
        expect(BuddyDeliverWorker).not_to have_received(:perform_async)
      end

      it "marks the bubble so the thread and Buddy both know what it was" do
        expect(send!(".garage door open").metadata["kind"]).to eq("jarvis")
      end

      it "still sends an ordinary message to Buddy" do
        send!("garage door open")

        expect(BuddyDeliverWorker).to have_received(:perform_async)
        expect(ByteJarvisWorker).not_to have_received(:perform_async)
      end

      # Nothing gets first refusal on a "." — or the same words would do two
      # different things depending on which thread they were typed in.
      it "is not swallowed by the timer fast path" do
        expect(::Buddy::Timers).not_to receive(:quick_set!)

        send!(".5m pasta")
        expect(ByteJarvisWorker).to have_received(:perform_async)
      end

      it "is not swallowed by the armed stash latch" do
        allow(::Buddy::Stash).to receive(:armed_category).and_return("thought")
        expect(::Buddy::Stash).not_to receive(:capture!)

        send!(".garage door open")
        expect(ByteJarvisWorker).to have_received(:perform_async)
      end

      # Jarvis drives the house, the car and the printer. /mode already refuses a
      # buddy-only member a jarvis thread; a prefix must not be the way around it.
      it "does nothing for anyone but the owner" do
        other = create(:user)
        theirs = other.byte_conversations.create!(mode: :buddy, name: "Theirs")

        send!(".garage door open", as: other, conversation: theirs)
        expect(ByteJarvisWorker).not_to have_received(:perform_async)
      end
    end
  end
end

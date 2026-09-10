require "rails_helper"

# The pet's face moves on its own in exactly one situation: the model wrote a
# reply and didn't say what the face should be. That used to be a `.sample` from
# a three-item "pleased" list, taken the moment a tool succeeded and reading
# nothing at all.
#
# Prod 5759, 9 Sep 2026 — Rocco: "Corporate Tools, the company I applied for that
# I've been most excited about, rejected me." Byte logged it, the reply said
# "*sad*" in words, and the pet put its GLASSES on, because the toss came up
# `nerd`. The face and the sentence were about different conversations.
#
# So the face is chosen now: read the room, then take the nearest face to what
# was read. `nerd` is back in play — what it needed was never removal, it was a
# sense of how serious the moment is.
RSpec.describe Buddy::Sentiment do
  let(:user)  { User.me }
  let(:convo) { user.byte_conversations.create!(mode: :buddy).tap { |c| c.update!(buddy_theme: "byte") } }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    # spec/support/buddy_sentiment.rb answers "couldn't read it" for the whole
    # suite so no unrelated example calls out. This is the file that means to.
    allow(described_class).to receive(:read).and_call_original
  end

  def say(body, direction: :inbound, **metadata)
    convo.byte_messages.create!(
      user: user, direction: direction, state: :delivered, body: body,
      metadata: metadata.stringify_keys
    )
  end

  # The real client, answering the way the real one does.
  def answering(json)
    allow(Buddy::GPT::Client).to receive(:new).and_return(
      instance_double(Buddy::GPT::Client, stream: { ok: true, text: json, usage: {} }),
    )
  end

  def refusing
    allow(Buddy::GPT::Client).to receive(:new).and_return(
      instance_double(Buddy::GPT::Client, stream: { ok: false, text: "", error: "boom", usage: {} }),
    )
  end

  describe "picking a face from a reading" do
    # The one that matters. Heavy and bleak has to reach a heavy, bleak face,
    # and the thing that makes that possible is `weight` — `nerd` and `sad` are
    # miles apart on it and were indistinguishable to a table that only knew
    # "pleased" from "not pleased".
    it "wears the room when the news is bad" do
      expect(Buddy::Faces.nearest(:byte, { warmth: 0.1, play: 0.05, weight: 0.85, strain: 0.2 })).to eq(:sad)
    end

    it "still reaches the clever face for a light, pleased, slightly nerdy moment" do
      expect(Buddy::Faces.nearest(:byte, { warmth: 0.7, play: 0.5, weight: 0.35, strain: 0.05 })).to eq(:nerd)
    end

    it "reaches a plain pleased face for an ordinary win" do
      expect(Buddy::Faces.nearest(:byte, { warmth: 0.85, play: 0.4, weight: 0.15, strain: 0.05 })).to eq(:happy)
    end

    it "reaches a silly one when they're mucking about" do
      expect(Buddy::Faces.nearest(:byte, { warmth: 0.85, play: 0.95, weight: 0.1, strain: 0.05 }))
        .to be_in(%i[uwu playful])
    end

    it "reaches a strained one when they're fed up" do
      expect(Buddy::Faces.nearest(:byte, { warmth: 0.25, play: 0.2, weight: 0.4, strain: 0.85 })).to eq(:annoyed)
    end

    # Each theme has a different set and must answer from its OWN — a reading
    # is theme-independent, a face never is.
    it "answers out of the theme's own faces" do
      %w[byte moss suki glimmer].each { |theme|
        face = Buddy::Faces.nearest(theme, { warmth: 0.9, play: 0.5, weight: 0.2, strain: 0.05 })
        expect(Buddy::Faces.selectable?(theme, face)).to be(true), "#{theme} answered #{face.inspect}"
      }
    end

    # A face with no profile can never be picked, which is a silent way for a
    # newly-added one to be unreachable.
    it "has a profile for every face any theme can wear" do
      %w[byte moss suki glimmer].each { |theme|
        missing = Buddy::Faces.selectable(theme).reject { |face| Buddy::Faces.profile(face) }
        expect(missing).to be_empty, "#{theme} has no profile for #{missing.inspect}"
      }
    end
  end

  describe "reading the thread" do
    it "sends both sides, oldest first, with the mood markers stripped" do
      say("Corporate Tools rejected me.", direction: :outbound)
      say("[[mood:sad]]Ohhh. That's a rough one.", kind: "buddy")

      client = instance_double(Buddy::GPT::Client)
      allow(Buddy::GPT::Client).to receive(:new).and_return(client)
      allow(client).to receive(:stream).and_return(
        { ok: true, text: '{"warmth":0.1,"play":0.0,"weight":0.9,"strain":0.2}', usage: {} },
      )

      described_class.read(convo)

      expect(client).to have_received(:stream) { |instructions:, input:, **|
        text = input.first[:content].first[:text]
        expect(text).to start_with("Them: Corporate Tools rejected me.")
        expect(text).to include("Companion: Ohhh. That's a rough one.")
        expect(text).not_to include("[[mood:")
        expect(instructions).to include("warmth")
      }
    end

    # Receipt chips and hidden trigger seeds are not things anyone said.
    it "leaves out the chips and the hidden seeds" do
      say("Real words here.", direction: :outbound)
      say("Logged it", kind: "buddy_activity")
      say("Give me an affirmation", hidden: true)

      expect(described_class.transcript_for(convo)).to eq("Them: Real words here.")
    end

    it "is nothing at all on an empty thread" do
      expect(described_class.read(convo)).to be_nil
    end
  end

  describe "settling the face" do
    before { say("I got turned down.", direction: :outbound) }

    it "sets the face nearest what it read" do
      answering('{"warmth":0.1,"play":0.05,"weight":0.85,"strain":0.2}')

      described_class.settle!(convo, acted: true, landed: true)

      expect(convo.reload.buddy_expression).to eq("sad")
    end

    # A turn that DIDN'T land is a fact about the action, not about the room, so
    # the reading is blended toward it rather than replaced. Prod 4594 was a
    # gleeful laugh over "I couldn't get a frame from the backyard camera".
    it "blends toward the miss faces when the action failed" do
      answering('{"warmth":0.85,"play":0.45,"weight":0.2,"strain":0.05}')

      described_class.settle!(convo, acted: true, landed: false)

      expect(convo.reload.buddy_expression).not_to eq("happy")
    end

    # The three ways prod 5759's turn could have gone, all landing in the same
    # place. Having done the person a small favour, or having failed to, are
    # facts about the errand - neither is an argument about how their day is
    # going, and the face has to say the day.
    it "stays with the room however the errand went" do
      bleak = '{"warmth":0.1,"play":0.05,"weight":0.85,"strain":0.2}'

      %i[talking landed missed].each { |shape|
        convo.update_column(:buddy_expression, "neutral")
        answering(bleak)

        described_class.settle!(
          convo, acted: shape != :talking, landed: shape != :missed
        )

        expect(convo.reload.buddy_expression).to eq("sad"), "#{shape} wore #{convo.buddy_expression}"
      }
    end

    # ...and the other half of that: a small favour in an ORDINARY moment does
    # move the face, or the pet is a machine accepting a command.
    it "warms up for a favour done in a flat moment" do
      answering('{"warmth":0.55,"play":0.3,"weight":0.1,"strain":0.05}')

      described_class.settle!(convo, acted: true, landed: true)

      expect(convo.reload.buddy_expression).not_to eq("neutral")
    end

    # It runs on every turn now, so it has to move a face that is already on -
    # that used to be the one thing it would never do.
    it "changes a face that is already on when the room has moved" do
      convo.update_column(:buddy_expression, "uwu")
      answering('{"warmth":0.1,"play":0.05,"weight":0.85,"strain":0.2}')

      described_class.settle!(convo, acted: false, landed: true)

      expect(convo.reload.buddy_expression).to eq("sad")
    end

    # ...and the other side of running every turn: it must NOT twitch. Two
    # readings a sentence apart landing either side of a boundary would flip the
    # pet between two near-identical faces for no reason anybody watching could
    # name, which is the face-changed-on-its-own glitch the old cycler job was
    # killed for.
    it "leaves a face that is already about as close as the new one" do
      convo.update_column(:buddy_expression, "happy")
      answering('{"warmth":0.8,"play":0.35,"weight":0.22,"strain":0.06}')

      described_class.settle!(convo, acted: false, landed: true)

      expect(convo.reload.buddy_expression).to eq("happy")
    end

    # The last reading is the most recent thing anybody knew, so keep it.
    it "keeps the face it has when the call doesn't come back" do
      convo.update_column(:buddy_expression, "loving")
      refusing

      described_class.settle!(convo, acted: true, landed: true)

      expect(convo.reload.buddy_expression).to eq("loving")
    end

    it "ignores an answer that isn't the four numbers" do
      answering("I'd say they seem a bit down today, honestly.")

      described_class.settle!(convo, acted: false, landed: true)

      expect(convo.reload.buddy_expression).to eq("neutral")
    end
  end

  describe "when it is worth asking at all" do
    it "queues on a buddy thread" do
      expect(BuddySentimentWorker).to receive(:perform_async).with(convo.id, true, true)
      described_class.later(convo, acted: true, landed: true)
    end

    # It used to skip a thread already wearing a face. It is the whole mood
    # system now, so there is nothing else to fall back to.
    it "queues even when a face is already on" do
      convo.update_column(:buddy_expression, "uwu")

      expect(BuddySentimentWorker).to receive(:perform_async).with(convo.id, true, true)
      described_class.later(convo, acted: true, landed: true)
    end

    it "does not queue for a thread that isn't Buddy's" do
      claude = user.byte_conversations.create!(mode: :claude)

      expect(BuddySentimentWorker).not_to receive(:perform_async)
      described_class.later(claude, acted: true, landed: true)
    end
  end
end

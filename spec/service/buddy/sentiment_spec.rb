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

    # `happy` moved on 18 Sep so that something could be glad about news that
    # MATTERS - see "good news about the job hunt" below. The cost is this
    # reading: bright, light and low-stakes now lands a step over on
    # `neutral_blush`, which is a warm face and a fair answer to a small win.
    # Byte has one glad face and two jobs for it; nothing sits in both places,
    # and the one this had to win is the one that was reading STERN.
    it "reaches a warm face for an ordinary light win" do
      expect(Buddy::Faces.nearest(:byte, { warmth: 0.85, play: 0.4, weight: 0.15, strain: 0.05 }))
        .to be_in(%i[happy neutral_blush])
    end

    it "reaches the plain pleased face for a win that matters" do
      expect(Buddy::Faces.nearest(:byte, { warmth: 0.85, play: 0.3, weight: 0.45, strain: 0.05 })).to eq(:happy)
    end

    it "reaches a silly one when they're mucking about" do
      expect(Buddy::Faces.nearest(:byte, { warmth: 0.85, play: 0.95, weight: 0.1, strain: 0.05 }))
        .to be_in(%i[uwu playful])
    end

    it "reaches a strained one when they're fed up" do
      expect(Buddy::Faces.nearest(:byte, { warmth: 0.25, play: 0.2, weight: 0.4, strain: 0.85 })).to eq(:annoyed)
    end

    # Prod 5890-5894. Stressed read as high strain, `annoyed` was the nearest
    # Byte face, and the pet wore a furrowed brow through its own offer to
    # cheer him up. Two things were wrong and this is the second: the lookup
    # MIRRORS a reading, and mirroring distress hands back a scowl aimed at the
    # person in it.
    it "never scowls at someone who is the one having the bad time" do
      carrying = { warmth: 0.2, play: 0.2, weight: 0.6, strain: 0.7 }

      expect(Buddy::Faces.nearest(:byte, carrying)).to eq(:annoyed)
      skip = described_class.skipped(carrying, false, true)
      expect(Buddy::Faces.nearest(:byte, carrying, skip: skip)).not_to be_in(Buddy::Faces::IRRITATED)
    end

    # ...and the other half, or the rule is a mute button. Being briefly fed up
    # with a companion that can't find a light switch is low warmth too; what
    # separates it is that nothing is at stake.
    it "still scowls when the friction is with the pet over something small" do
      niggle = { warmth: 0.25, play: 0.2, weight: 0.4, strain: 0.85 }

      expect(described_class.skipped(niggle, false, true)).to be_empty
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

  describe "what the axes are asked for" do
    # The first half of prod 5890. `strain` used to read "how much friction is
    # in the room", which a stressed person satisfies without being in any
    # friction with anybody - and every high-strain face is a scowl.
    it "puts the person's own pressure on weight, not on strain" do
      expect(described_class::PROMPT).to include("Pressure from their own life is NOT strain")
      expect(described_class::PROMPT).to include("friction in THIS exchange")
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

    # Prod 18 Sep. Rocco: "he's often using the focused/angry face for those
    # which feels inappropriate." An ATS auto-reply is a small moment, but the
    # window it was read from held eight companion lines and none of his - two
    # of them rejections - so the reading was of a long hard day.
    describe "a turn nobody started" do
      before {
        say("Epicor said they're not moving forward.", kind: "buddy")
        say("Machinify says your application was received.", kind: "buddy")
      }

      it "says so, so the last line is readable as the moment" do
        text = described_class.transcript_for(convo, unprompted: true)

        expect(text.lines.last.strip).to eq(described_class::UNPROMPTED_NOTE)
        expect(text).to include("Companion: Machinify says your application was received.")
      end

      it "says nothing of the sort about an ordinary exchange" do
        text = described_class.transcript_for(convo)

        expect(text).not_to include(described_class::UNPROMPTED_NOTE)
      end

      # The note is about the transcript, so an empty one must not consist of
      # only the note - `read` bails on a blank transcript and that gate has to
      # keep working.
      it "does not stand alone on an empty thread" do
        convo.byte_messages.destroy_all

        expect(described_class.transcript_for(convo.reload, unprompted: true)).to eq("")
      end
    end
  end

  # Rocco, 18 Sep: "receiving an email back from a potential job, as long as
  # it's not a rejection, seems like it should be a GOOD thing. As is marking a
  # job as applied. It feels like Byte should be encouraging there."
  #
  # Measured against the real model on the prod windows: an acknowledgement, an
  # application going out and an interview being booked all land on `happy`
  # now, and a rejection still lands on `sad`.
  describe "good news about the job hunt" do
    def face_for(reading, unprompted: true)
      skip = described_class.send(:skipped, reading, false, true, unprompted: unprompted)
      Buddy::Faces.nearest("byte", reading, skip: skip)
    end

    # Warm, dead earnest, and genuinely at stake. Before this it was the one
    # shape with nowhere to go: `happy` was pinned to "a small win" at weight
    # 0.20, so the nearest face was `loving` — hearts, at an ATS.
    it "is glad about something that matters" do
      expect(face_for({ warmth: 0.8, play: 0.0, weight: 0.8, strain: 0.0 })).to eq(:happy)
    end

    it "is still sad about a rejection" do
      expect(face_for({ warmth: 0.1, play: 0.0, weight: 0.8, strain: 0.0 })).to eq(:sad)
    end

    # The original complaint. `focused` reads STERN and was what every job-shaped
    # reading fell to.
    it "is not stern about a routine confirmation" do
      expect(face_for({ warmth: 0.7, play: 0.0, weight: 0.4, strain: 0.0 })).not_to eq(:focused)
    end
  end

  # Affection needs somebody to feel it toward, and the four axes cannot say
  # what a warm weighty moment is warm ABOUT — an interview being booked and a
  # note left in his bag land within a hundredth of each other. What IS known is
  # whether anybody spoke.
  describe "the tender faces" do
    let(:warm) { { warmth: 0.9, play: 0.0, weight: 0.6, strain: 0.0 } }

    it "are out of reach on a turn nobody started" do
      expect(described_class.send(:skipped, warm, false, true, unprompted: true)).to include(:loving)
      expect(Buddy::Faces.nearest("byte", warm, skip: [:loving])).to eq(:happy)
    end

    it "are exactly where they were in a conversation" do
      skip = described_class.send(:skipped, warm, false, true, unprompted: false)

      expect(skip).not_to include(:loving)
      expect(Buddy::Faces.nearest("byte", warm, skip: skip)).to eq(:loving)
    end
  end

  describe "what a reading is told about the size of a moment" do
    # The other half of the same afternoon: `weight` read the SUBJECT rather
    # than the event, and its own wording asked for that - "1 is something that
    # genuinely matters - work, health, money, family". Anything about the job
    # hunt was therefore maximal, which put `focused` (weight 0.85) on a robot
    # saying it had received a form.
    it "asks about the event rather than the subject it belongs to" do
      expect(described_class::PROMPT).to include("Judge the EVENT, not the subject")
      expect(described_class::PROMPT).to include("a routine confirmation")
    end

    it "says news counts in both directions, not only the bad kind" do
      expect(described_class::PROMPT).to include("it counts BOTH WAYS")
      expect(described_class::PROMPT).to include("is genuinely GOOD news")
    end

    it "tells it what an unprompted last line means" do
      expect(described_class::PROMPT).to include("delivering news on its own")
      expect(described_class::PROMPT).to include("strain is 0")
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
      answering('{"warmth":0.83,"play":0.28,"weight":0.47,"strain":0.06}')

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
      expect(BuddySentimentWorker).to receive(:perform_async).with(convo.id, true, true, false)
      described_class.later(convo, acted: true, landed: true)
    end

    # It used to skip a thread already wearing a face. It is the whole mood
    # system now, so there is nothing else to fall back to.
    it "queues even when a face is already on" do
      convo.update_column(:buddy_expression, "uwu")

      expect(BuddySentimentWorker).to receive(:perform_async).with(convo.id, true, true, false)
      described_class.later(convo, acted: true, landed: true)
    end

    it "does not queue for a thread that isn't Buddy's" do
      claude = user.byte_conversations.create!(mode: :claude)

      expect(BuddySentimentWorker).not_to receive(:perform_async)
      described_class.later(claude, acted: true, landed: true)
    end
  end
end

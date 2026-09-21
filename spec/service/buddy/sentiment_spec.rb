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
        missing = Buddy::Faces.selectable(theme).reject { |face| Buddy::Faces.profile(face, theme) }
        expect(missing).to be_empty, "#{theme} has no profile for #{missing.inspect}"
      }
    end

    # Having a profile is not the same as having somewhere to BE. Two faces at
    # one point means one of them is art nobody ever sees, and nothing else
    # says so - the lookup just never returns it.
    it "leaves every face somewhere it wins" do
      grid = (0..10).step(2).to_a
      readings = grid.product(grid, grid, grid).map { |w, p, g, s|
        { warmth: w / 10.0, play: p / 10.0, weight: g / 10.0, strain: s / 10.0 }
      }

      %w[byte moss suki glimmer].each { |theme|
        reached = readings.map { |reading| Buddy::Faces.nearest(theme, reading, skip: []) }.uniq
        unreachable = Buddy::Faces.selectable(theme) - reached
        expect(unreachable).to be_empty, "#{theme} can never show #{unreachable.inspect}"
      }
    end
  end

  # Rocco, 21 Sep 2026, on the face after almost every errand: "The Content
  # face used to be something a bit different. This new one was recently added
  # and I don't think it quite fits."
  #
  # Byte's `content` art landed on 18 Sep and reused the row written for Moss's
  # eight days earlier. Moss's is a round mossy ball with its eyes closed and
  # the row said so - `play: 0.15`, the quiet warm corner every ordinary "done"
  # reading falls into. Byte's is squashed flat with gold sparkles, which is
  # not serenity, and it inherited the corner anyway. Buddy::Faces::INDEX is
  # keyed by theme now, so each drawing gets its own numbers.
  # Rocco, 21 Sep 2026: "we should use the numbers and ratings - possibly even
  # using ranges to fit. Then when the current message is given with its
  # ratings, we choose based on that. Ideally when there are multiple close
  # matches, we have a weighted select... However, we want to ensure that only
  # relevant matches are included, which is why there was a thought to use
  # ranges for these instead."
  describe "the range each face answers within" do
    it "keeps the loud ones out of an ordinary bad moment" do
      rejection = { warmth: 0.1, play: 0.05, weight: 0.8, strain: 0.2 }

      expect(Buddy::Faces.pool("byte", rejection).map(&:first)).not_to include(:crying)
    end

    # The complaint that started the weight axis, and it comes back the moment
    # a stern face is allowed to answer a bleak one.
    it "keeps the stern one off a rejection" do
      rejection = { warmth: 0.1, play: 0.05, weight: 0.85, strain: 0.2 }

      expect(Buddy::Faces.pool("byte", rejection).map(&:first)).not_to include(:focused)
    end

    it "still lets the loud one answer the moment it is actually for" do
      grief = { warmth: 0.05, play: 0.0, weight: 0.95, strain: 0.3 }

      expect(Buddy::Faces.pool("byte", grief).map(&:first)).to include(:crying)
    end

    # A range says who ELSE may answer. It must never leave a reading with
    # nobody, so the closest face is in whatever the ranges say - twenty faces
    # in a four-axis cube are sparse, and a pet with no face is worse than a
    # pet wearing the nearest thing to what it was told.
    it "always leaves somebody to answer" do
      grid = (0..10).step(2).to_a
      readings = grid.product(grid, grid, grid).map { |w, p, g, s|
        { warmth: w / 10.0, play: p / 10.0, weight: g / 10.0, strain: s / 10.0 }
      }

      empty = readings.reject { |reading| Buddy::Faces.pool("byte", reading).any? }

      expect(empty).to be_empty
    end
  end

  describe "choosing between faces that all fit" do
    let(:light_win) { { warmth: 0.85, play: 0.45, weight: 0.2, strain: 0.05 } }

    it "offers more than one answer where there is more than one" do
      expect(Buddy::Faces.pool("byte", light_win).length).to be > 1
    end

    # The whole point of the draw: a perfect match does not silence the faces
    # standing next to it, or they are art nobody sees on the days they fit.
    it "does not always take the closest" do
      rng = Random.new(3)
      drawn = 400.times.map { Buddy::Faces.pick("byte", light_win, rng: rng) }.uniq

      expect(drawn.length).to be > 1
    end

    # ...but it is still the likeliest by some way. See Faces::SOFTNESS.
    it "favours the closest" do
      rng = Random.new(3)
      drawn = 400.times.map { Buddy::Faces.pick("byte", light_win, rng: rng) }
      best = Buddy::Faces.nearest("byte", light_win)

      expect(drawn.tally.max_by(&:last).first).to eq(best)
      expect(drawn.count(best)).to be > (drawn.length / 3)
    end

    it "is repeatable when the draw is pinned" do
      once = 20.times.map { Buddy::Faces.pick("byte", light_win, rng: Random.new(99)) }

      expect(once.uniq.length).to eq(1)
    end

    it "never draws a face the turn put away" do
      rng = Random.new(5)
      drawn = 200.times.map { Buddy::Faces.pick("byte", light_win, skip: %i[happy thumbs_up], rng: rng) }

      expect(drawn & %i[happy thumbs_up]).to be_empty
    end
  end

  describe "a face name that means two different drawings" do
    def everyday
      (5..9).to_a.product((2..6).to_a, (1..4).to_a, (0..2).to_a).map { |w, p, g, s|
        { warmth: w / 10.0, play: p / 10.0, weight: g / 10.0, strain: s / 10.0 }
      }
    end

    it "gives each pet its own row" do
      expect(Buddy::Faces.profile(:content, :byte)).not_to eq(Buddy::Faces.profile(:content, :moss))
    end

    it "puts Byte's where its art is - light, not serene" do
      expect(Buddy::Faces.profile(:content, :byte)[:play]).to be > Buddy::Faces.profile(:content, :moss)[:play]
    end

    # No rule about it any more: the row says what the drawing is, and that
    # alone takes it off the ordinary errand.
    it "stops it being Byte's answer to an ordinary errand" do
      rng = Random.new(11)
      faces = everyday.flat_map { |reading|
        skip = described_class.send(:skipped, reading, true, true)
        blended = described_class.send(:blended, reading, true)
        5.times.map { Buddy::Faces.pick("byte", blended, skip: skip, rng: rng) }
      }

      expect(faces.count(:content)).to be < (faces.length / 10)
    end

    # Rocco: "I'm fine with the squish expression still occasionally popping
    # up." Moved, not removed.
    it "keeps it reachable" do
      delighted = { warmth: 0.9, play: 0.7, weight: 0.15, strain: 0.05 }

      expect(Buddy::Faces.pool("byte", delighted).map(&:first)).to include(:content)
    end
  end

  describe "the tender faces" do
    let(:warm) { { warmth: 0.9, play: 0.0, weight: 0.6, strain: 0.0 } }

    it "are out of reach on a turn nobody started" do
      skip = described_class.send(:skipped, warm, false, true, unprompted: true)

      expect(skip).to include(:loving, :hugging, :caring)
      expect(Buddy::Faces.nearest("byte", warm, skip: skip)).not_to be_in(Buddy::Faces::TENDER)
    end

    it "are exactly where they were in a conversation" do
      skip = described_class.send(:skipped, warm, false, true, unprompted: false)

      expect(skip).not_to include(:loving)
      expect(Buddy::Faces.nearest("byte", warm, skip: skip)).to be_in(Buddy::Faces::TENDER)
    end

    # Spread along `weight` so each one is actually reachable: a kind word, then
    # being smitten, then holding something dear. Two faces at one point means
    # one of them is art nobody ever sees.
    it "are three distinct faces, not three names for one" do
      reached = [0.3, 0.6, 0.85].map { |weight|
        Buddy::Faces.nearest("byte", { warmth: 0.9, play: 0.15, weight: weight, strain: 0.05 }, skip: [])
      }

      expect(reached).to eq(%i[caring loving hugging])
    end
  end

  # Rocco, 21 Sep 2026: "I preferred the thumbs one instead."
  #
  # `thumbs_up` is the one face that means "that's sorted", and it sits within a
  # tenth of `neutral_blush` and `nerd` on all four axes - so a timer got set
  # and the pet blushed or put its glasses on instead. Across the band an
  # everyday errand actually reads in, those two took more than half the turns
  # and `thumbs_up` took one in nine.
  describe "the face on a turn that did the thing" do
    # Pleased-ish, light-ish, not much at stake, no friction: an ordinary
    # "do this for me" exchange, and what most of them read as.
    def everyday
      (5..9).to_a.product((2..6).to_a, (1..4).to_a, (0..2).to_a).map { |w, p, g, s|
        { warmth: w / 10.0, play: p / 10.0, weight: g / 10.0, strain: s / 10.0 }
      }
    end

    def landed_on(reading)
      skip = described_class.send(:skipped, reading, true, true)
      Buddy::Faces.nearest("byte", described_class.send(:blended, reading, true), skip: skip)
    end

    it "is never being flattered or being clever" do
      faces = everyday.map { |reading| landed_on(reading) }.uniq

      expect(faces).not_to include(:neutral_blush, :nerd)
    end

    it "reaches the one that means it" do
      faces = everyday.map { |reading| landed_on(reading) }

      expect(faces.count(:thumbs_up)).to be > (faces.length / 5)
    end

    # `happy` is right whenever the thing that got done is good news for THEM,
    # and it must keep those - one face cannot be both.
    it "still leaves the warm ones to the warm moments" do
      faces = everyday.map { |reading| landed_on(reading) }

      expect(faces).to include(:happy)
    end

    # Both are honest readings of a turn that only talked, and neither is
    # taken away there.
    it "leaves both of them reachable when nothing was done" do
      skip = described_class.send(:skipped, { warmth: 0.7, play: 0.5, weight: 0.35, strain: 0.05 }, false, true)

      expect(skip).to be_empty
    end
  end

  describe "what a reading is told about the size of a moment" do
    # `weight` is about the size of the EVENT. Wording it as a list of subject
    # areas ("work, health, money") makes anything job-shaped maximal, which is
    # how a robot confirming a form reaches a weight-0.85 face.
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
      answering('{"warmth":0.83,"play":0.43,"weight":0.22,"strain":0.06}')

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

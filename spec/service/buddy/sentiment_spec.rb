require "rails_helper"

# The pet's face is chosen by reading the room (four axes: warmth, play,
# weight, strain) and taking the nearest face in the theme's own set.
RSpec.describe Buddy::Sentiment do
  let(:user)  { User.me }
  let(:convo) { user.byte_conversations.create!(mode: :buddy).tap { |c| c.update!(buddy_theme: "byte") } }
  let(:themes) { %w[byte moss suki glimmer kumoko mocha ghosty] }

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

  def grid_readings
    grid = (0..10).step(2).to_a
    grid.product(grid, grid, grid).map { |w, p, g, s|
      { warmth: w / 10.0, play: p / 10.0, weight: g / 10.0, strain: s / 10.0 }
    }
  end

  # Pleased-ish, light-ish, not much at stake, no friction: what most ordinary
  # "do this for me" exchanges read as.
  def everyday
    (5..9).to_a.product((2..6).to_a, (1..4).to_a, (0..2).to_a).map { |w, p, g, s|
      { warmth: w / 10.0, play: p / 10.0, weight: g / 10.0, strain: s / 10.0 }
    }
  end

  describe "picking a face from a reading" do
    it "maps each kind of moment to its nearest byte face", :aggregate_failures do
      [
        [{ warmth: 0.1, play: 0.05, weight: 0.85, strain: 0.2 }, %i[sad]],
        [{ warmth: 0.7, play: 0.5, weight: 0.35, strain: 0.05 }, %i[nerd]],
        [{ warmth: 0.85, play: 0.4, weight: 0.15, strain: 0.05 }, %i[happy]],
        [{ warmth: 0.85, play: 0.95, weight: 0.1, strain: 0.05 }, %i[uwu playful]],
        [{ warmth: 0.25, play: 0.2, weight: 0.4, strain: 0.85 }, %i[annoyed]],
      ].each { |reading, faces|
        expect(Buddy::Faces.nearest(:byte, reading)).to be_in(faces), reading.inspect
      }
    end

    # The lookup mirrors a reading, and mirroring distress would scowl at the
    # person who is having the bad time.
    it "never scowls at someone who is the one having the bad time" do
      carrying = { warmth: 0.2, play: 0.2, weight: 0.6, strain: 0.7 }

      expect(Buddy::Faces.nearest(:byte, carrying)).to eq(:annoyed)
      skip = described_class.skipped(carrying, false, true)
      expect(Buddy::Faces.nearest(:byte, carrying, skip: skip)).not_to be_in(Buddy::Faces::IRRITATED)
    end

    # Friction with the pet over something small has nothing at stake.
    it "still scowls when the friction is with the pet over something small" do
      niggle = { warmth: 0.25, play: 0.2, weight: 0.4, strain: 0.85 }

      expect(described_class.skipped(niggle, false, true)).to be_empty
    end

    it "answers out of each theme's own faces, all of which have a profile", :aggregate_failures do
      themes.each { |theme|
        face = Buddy::Faces.nearest(theme, { warmth: 0.9, play: 0.5, weight: 0.2, strain: 0.05 })
        expect(Buddy::Faces.selectable?(theme, face)).to be(true), "#{theme} answered #{face.inspect}"

        missing = Buddy::Faces.selectable(theme).reject { |f| Buddy::Faces.profile(f, theme) }
        expect(missing).to be_empty, "#{theme} has no profile for #{missing.inspect}"
      }
    end

    # Two faces at one point means one of them is never returned.
    it "leaves every face somewhere it wins", :aggregate_failures do
      readings = grid_readings

      themes.each { |theme|
        reached = readings.map { |reading| Buddy::Faces.nearest(theme, reading, skip: []) }.uniq
        unreachable = Buddy::Faces.selectable(theme) - reached
        expect(unreachable).to be_empty, "#{theme} can never show #{unreachable.inspect}"
      }
    end
  end

  describe "the range each face answers within" do
    it "keeps loud and stern faces off an ordinary bad moment but lets the loud one answer grief", :aggregate_failures do
      rejection = Buddy::Faces.pool("byte", { warmth: 0.1, play: 0.05, weight: 0.8, strain: 0.2 }).map(&:first)
      bleaker = Buddy::Faces.pool("byte", { warmth: 0.1, play: 0.05, weight: 0.85, strain: 0.2 }).map(&:first)
      grief = Buddy::Faces.pool("byte", { warmth: 0.05, play: 0.0, weight: 0.95, strain: 0.3 }).map(&:first)

      expect(rejection).not_to include(:crying)
      expect(bleaker).not_to include(:focused)
      expect(grief).to include(:crying)
    end

    # The closest face is always in the pool, whatever the ranges say.
    it "always leaves somebody to answer" do
      empty = grid_readings.reject { |reading| Buddy::Faces.pool("byte", reading).any? }

      expect(empty).to be_empty
    end
  end

  describe "choosing between faces that all fit" do
    let(:light_win) { { warmth: 0.85, play: 0.45, weight: 0.2, strain: 0.05 } }

    it "draws from several faces but favours the closest", :aggregate_failures do
      rng = Random.new(3)
      drawn = 400.times.map { Buddy::Faces.pick("byte", light_win, rng: rng) }
      best = Buddy::Faces.nearest("byte", light_win)

      expect(Buddy::Faces.pool("byte", light_win).length).to be > 1
      expect(drawn.uniq.length).to be > 1
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

  describe "byte's content face" do
    it "is rarely the answer to an ordinary errand" do
      rng = Random.new(11)
      faces = everyday.flat_map { |reading|
        skip = described_class.send(:skipped, reading, true, true)
        blended = described_class.send(:blended, reading, true)
        5.times.map { Buddy::Faces.pick("byte", blended, skip: skip, rng: rng) }
      }

      expect(faces.count(:content)).to be < (faces.length / 10)
    end

    it "is still reachable for a delighted moment" do
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

    it "are three distinct faces spread along weight" do
      reached = [0.3, 0.6, 0.85].map { |weight|
        Buddy::Faces.nearest("byte", { warmth: 0.9, play: 0.15, weight: weight, strain: 0.05 }, skip: [])
      }

      expect(reached).to eq(%i[caring loving hugging])
    end
  end

  describe "an exchange that ended hours ago" do
    def at(when_at, body, **rest)
      say(body, **rest).tap { |m| m.update_columns(created_at: when_at, updated_at: when_at) }
    end

    before do
      at(4.hours.ago, "You're still sounding the same as you did before.", direction: :outbound)
      at(4.hours.ago, "Fair hit. Let me swing it a little more my way then.")
      at(2.minutes.ago, "Laundry gate is shut")
      at(1.minute.ago, "Morning. You've got a loaded one.")
    end

    it "reads what is on this side of the silence and nothing older" do
      transcript = described_class.transcript_for(convo)

      expect(transcript).to include("loaded one")
      expect(transcript).not_to include("sounding the same")
    end

    it "keeps a conversation with ordinary pauses in it whole" do
      at(20.minutes.ago, "What's the plan for today?", direction: :outbound)

      expect(described_class.transcript_for(convo)).to include("What's the plan for today?")
    end

    it "never answers nothing, however long ago the newest line was" do
      convo.byte_messages.destroy_all
      at(3.days.ago, "Reminder: Focus")

      expect(described_class.transcript_for(convo)).to include("Reminder: Focus")
    end
  end

  describe "strain on a turn nobody started" do
    before { say("Morning. You've got a loaded one.") }

    it "is zeroed when unprompted and left as read otherwise", :aggregate_failures do
      answering('{"warmth":0.3,"play":0.2,"weight":0.5,"strain":0.8}')

      expect(described_class.read(convo, unprompted: true)[:strain]).to eq(0.0)
      expect(described_class.read(convo)[:strain]).to eq(0.8)
    end

    it "keeps a cross face off a briefing" do
      answering('{"warmth":0.45,"play":0.2,"weight":0.5,"strain":0.8}')

      described_class.settle!(convo, unprompted: true)

      expect(Buddy::Faces::IRRITATED.map(&:to_s)).not_to include(convo.reload.buddy_expression)
    end
  end

  describe "the face on a turn that did the thing" do
    def landed_on(reading)
      skip = described_class.send(:skipped, reading, true, true)
      Buddy::Faces.nearest("byte", described_class.send(:blended, reading, true), skip: skip)
    end

    it "is mostly thumbs_up, sometimes happy, never blush or nerd", :aggregate_failures do
      faces = everyday.map { |reading| landed_on(reading) }

      expect(faces.uniq).not_to include(:neutral_blush, :nerd)
      expect(faces.count(:thumbs_up)).to be > (faces.length / 5)
      expect(faces).to include(:happy)
    end

    it "skips nothing when nothing was done" do
      skip = described_class.send(:skipped, { warmth: 0.7, play: 0.5, weight: 0.35, strain: 0.05 }, false, true)

      expect(skip).to be_empty
    end
  end

  describe "settling the face" do
    before { say("I got turned down.", direction: :outbound) }

    it "blends toward the miss faces when the action failed" do
      answering('{"warmth":0.85,"play":0.45,"weight":0.2,"strain":0.05}')

      described_class.settle!(convo, acted: true, landed: false)

      expect(convo.reload.buddy_expression).not_to eq("happy")
    end

    # The errand's outcome blends the reading; it must not override a bleak room.
    it "stays with the room however the errand went" do
      # Pin the draw to the nearest so this tests where the room points, not
      # the tie-break between sad and confused.
      allow(Random).to receive(:rand).and_return(0.0)
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

    it "warms up for a favour done in a flat moment" do
      answering('{"warmth":0.55,"play":0.3,"weight":0.1,"strain":0.05}')

      described_class.settle!(convo, acted: true, landed: true)

      expect(convo.reload.buddy_expression).not_to eq("neutral")
    end

    it "changes a face that is already on when the room has moved" do
      convo.update_column(:buddy_expression, "uwu")
      answering('{"warmth":0.1,"play":0.05,"weight":0.85,"strain":0.2}')

      described_class.settle!(convo, acted: false, landed: true)

      expect(convo.reload.buddy_expression).to eq("sad")
    end

    # Two near-identical readings must not flip between neighbouring faces.
    it "leaves a face that is already about as close as the new one" do
      convo.update_column(:buddy_expression, "happy")
      answering('{"warmth":0.83,"play":0.43,"weight":0.22,"strain":0.06}')

      described_class.settle!(convo, acted: false, landed: true)

      expect(convo.reload.buddy_expression).to eq("happy")
    end

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
    it "queues on a buddy thread even when a face is already on" do
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

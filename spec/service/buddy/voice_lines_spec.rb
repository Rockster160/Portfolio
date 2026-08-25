require "rails_helper"

# A routine tapped on the Quick grid or the kiosk runs with no model behind it,
# so the line over it is ours to write — and written once, it came out of every
# companion identically. Chelsea's firefly announced her yoga lamp with
# "Running **Yoga Lamp**", which is a job scheduler talking.
#
# So the words are per-pet, and each line carries the FACE that goes with it:
# the persona's own rule is that face and prose agree, and the only way they
# can't drift is if they're written down together.
RSpec.describe Buddy::VoiceLines do
  let(:user) { create(:user) }

  def convo!(theme)
    convo = user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current)
    convo.update_columns(buddy_theme: theme.to_s)
    convo
  end

  # The guard that matters most. A face is an image file, the art moves, and a
  # line asking for one this pet can't render would leave the pet blank — or
  # worse, resting on `thinking`, which is transitional and never a mood.
  describe "the table itself" do
    Buddy::VoiceLines::LINES.each do |theme, kinds|
      lines = kinds.values.flatten

      it "#{theme} only ever asks for a face #{theme} can wear" do
        expect(lines.reject { |line| Buddy::Faces.selectable?(theme, line[:mood]) }).to eq([])
      end

      it "#{theme} never rests on neutral, which is the whole point" do
        expect(lines.select { |line| line[:mood] == Buddy::Faces.default }).to eq([])
      end

      # Per kind, not per theme: the same hello belongs in more than one set —
      # "Hiii!" is as right at 2pm as it is at 2am — while a routine line
      # appearing twice in one set is a line with double the odds.
      kinds.each do |kind, of_kind|
        it "#{theme} says each #{kind} line only once" do
          expect(of_kind.pluck(:say).tally.select { |_say, n| n > 1 }).to eq({})
        end
      end
    end

    Buddy::VoiceLines::ACTED_MOODS.each do |theme, sets|
      sets.each do |outcome, moods|
        it "#{theme}'s #{outcome} acted faces are all renderable, and none of them is neutral" do
          expect(moods).to all(satisfy { |m| Buddy::Faces.selectable?(theme, m) })
          expect(moods).not_to include(Buddy::Faces.default)
        end
      end
    end

    it "gives every theme a line for every kind" do
      kinds = Buddy::VoiceLines::LINES.values.flat_map(&:keys).uniq
      Buddy::Themes::ALL.each_key { |theme|
        kinds.each { |kind| expect(described_class.lines_for(theme, kind)).to be_present }
      }
    end

    # The fallback only fires when Turn decides a hello is missing, so a
    # greeting the same check can't recognise would get a SECOND hello put in
    # front of it the next time a model happened to write it.
    it "writes greetings that read as greetings" do
      greetings = Buddy::VoiceLines::LINES.flat_map { |_theme, kinds|
        kinds.select { |kind, _| kind.to_s.start_with?("greeting_") }.values.flatten
      }

      expect(greetings).to be_present
      expect(greetings.reject { |line| line[:say].match?(Buddy::GPT::Turn::GREETING_OPENER_RX) }).to eq([])
    end

    # A hello that trails off on a period reads deadpan, and the line after it
    # inherits the flatness - which is the whole reason the prompt spends a
    # paragraph on it.
    it "lands every greeting lifted rather than flat" do
      greetings = Buddy::VoiceLines::LINES.flat_map { |_theme, kinds|
        kinds.select { |kind, _| kind.to_s.start_with?("greeting_") }.values.flatten
      }

      expect(greetings.select { |line| line[:say].end_with?(".") }).to eq([])
    end

    # The variety IS the feature. A pet with four lines is recognised inside a
    # week on a tablet somebody walks past all day, and a line you can predict
    # is one nobody reads - at which point it may as well have stayed "Running
    # X". So a new companion can't ship with two.
    it "gives every pet enough to say that it doesn't get predictable" do
      Buddy::VoiceLines::LINES.each { |theme, kinds|
        expect(kinds[:routine_run].length).to be >= 8, "#{theme} needs more routine_run lines"
      }
    end
  end

  describe ".pick" do
    it "puts the routine's name in the line" do
      line = described_class.pick(:glimmer, :routine_run, name: "Yoga Lamp")

      expect(line[:text]).to include("Yoga Lamp")
      expect(line[:mood]).to be_present
    end

    it "sounds like the pet whose line it is" do
      glimmer = described_class.lines_for(:glimmer, :routine_run).pluck(:say)
      byte    = described_class.lines_for(:byte, :routine_run).pluck(:say)

      expect(glimmer).not_to match_array(byte)
    end

    # Two taps in a row landing the same face is a pet that didn't react to the
    # second one.
    it "prefers a face the pet isn't already wearing" do
      20.times {
        line = described_class.pick(:glimmer, :routine_run, avoid: :content, name: "Yoga Lamp")
        expect(line[:mood]).not_to eq(:content)
      }
    end

    # Preferred, not required — a set of one still has to speak.
    it "still speaks when the only line left wears the face it's already wearing" do
      only = [{ say: "Doing **%<name>s**.", mood: :happy }]
      allow(described_class).to receive(:lines_for).and_return(only)

      line = described_class.pick(:glimmer, :routine_run, avoid: :happy, name: "Yoga Lamp")

      expect(line[:text]).to eq("Doing **Yoga Lamp**.")
    end

    # "Never the same hello twice running" was an instruction in the prompt.
    # This is the version that's true.
    it "never reuses the line that opened the last one" do
      repeated = described_class.lines_for(:byte, :greeting_morning).first[:say]

      20.times {
        line = described_class.pick(:byte, :greeting_morning, unlike: "#{repeated} Quiet day today.")
        expect(line[:text]).not_to eq(repeated)
      }
    end

    it "ignores `unlike` when it isn't how the last one opened" do
      expect {
        described_class.pick(:byte, :greeting_morning, unlike: "Quiet day today.")
      }.not_to raise_error
    end

    # The value arrives from a database column, same as Buddy::Themes.for.
    it "reads an unknown theme as the default rather than raising" do
      expect(described_class.pick(:nonesuch, :routine_run, name: "X")[:text]).to be_present
    end

    # A face that's been deleted from the art is "say the line, leave the face",
    # never a blank pet.
    it "drops a face the theme can't render" do
      expect(described_class.mood_for(:glimmer, :nerd)).to be_nil
      expect(described_class.mood_for(:glimmer, :thinking)).to be_nil
      expect(described_class.mood_for(:glimmer, :content)).to eq(:content)
    end
  end

  describe "running a routine" do
    let(:routine) {
      BuddyRoutine.create!(
        user:  user,
        name:  "Yoga Lamp",
        steps: [BuddyRoutine.step(:set_timer, { seconds: 60, label: "breathe" })],
      )
    }

    before {
      allow(MonitorChannel).to receive(:broadcast_to)
      # Inline Sidekiq would run the countdown out the instant it's set.
      allow(TimerFireWorker).to receive(:perform_at).and_return("jid")
    }

    it "announces it in the pet's own voice" do
      convo = convo!(:glimmer)
      said  = described_class.lines_for(:glimmer, :routine_run).map { |l| format(l[:say], name: "Yoga Lamp") }

      Buddy::Routines.run!(routine, conversation: convo)

      # The heading is the first line of the message; anything under it is the
      # steps reporting for themselves.
      expect(said).to include(convo.byte_messages.chronological.first.body.split("\n\n").first)
    end

    it "moves the face off neutral as it goes" do
      convo = convo!(:glimmer)

      Buddy::Routines.run!(routine, conversation: convo)

      expect(convo.reload.buddy_expression).to be_present
      expect(convo.buddy_expression).not_to eq(Buddy::Faces.default.to_s)
    end

    # The expression has to be there as the words land, not a beat behind them —
    # same ordering a `[[mood:]]` marker gets on a real reply.
    it "sets the face before it posts the line" do
      convo = convo!(:glimmer)
      order = []
      allow(Buddy::SideEffects).to receive(:apply_mood) { order << :face }
      allow(Buddy::ProposalBuilder).to receive(:run_markers!) {
        order << :words
        { action: nil, auto_ran: true, forms: [] }
      }

      Buddy::Routines.run!(routine, conversation: convo)

      expect(order).to eq(%i[face words])
    end

    # Every step dropped: the target is gone or the feature is off. The pet says
    # so in its own words, and doesn't keep the pleased face it just put on.
    it "drops out of the happy face when nothing in it ran" do
      convo = convo!(:glimmer)
      gone  = BuddyRoutine.create!(
        user: user, name: "Gone", steps: [BuddyRoutine.step(:complete_chore, { chore: "nothing by this name" })],
      )

      Buddy::Routines.run!(gone, conversation: convo)

      body   = convo.byte_messages.chronological.last.body
      excuse = described_class.lines_for(:glimmer, :routine_empty)
      expect(excuse.map { |l| l[:mood].to_s }).to include(convo.reload.buddy_expression)
      expect(excuse.any? { |l| body.include?(l[:say]) }).to be(true)
    end
  end

  # A companion that does the thing and keeps a flat face reads as a machine
  # taking an order.
  describe Buddy::ExpressionState do
    before { allow(MonitorChannel).to receive(:broadcast_to) }

    it "reacts when the pet was resting" do
      convo = convo!(:glimmer)

      described_class.react!(convo)

      expect(convo.reload.buddy_expression).not_to eq(Buddy::Faces.default.to_s)
      expect(Buddy::Faces.selectable?(:glimmer, convo.buddy_expression)).to be(true)
    end

    # The floor, not an override. A face the model chose this turn is a read of
    # the room — sitting with something heavy while it quietly cancels an alarm
    # — and stamping "pleased with myself" over it is the face-changed-on-its-own
    # glitch the module exists to prevent.
    it "leaves a face the model deliberately chose alone" do
      convo = convo!(:glimmer)
      convo.update_column(:buddy_expression, "sad")

      described_class.react!(convo)

      expect(convo.reload.buddy_expression).to eq("sad")
    end

    it "no-ops on no conversation at all" do
      expect { described_class.react!(nil) }.not_to raise_error
    end
  end

  # Prod 4594: "Hmm. I couldn't get a frame from the backyard camera, and it
  # didn't say why." wore `uwu` — an eyes-closed open-mouthed laugh. Nothing
  # picked it: the model chose no face, something had run, and this table was
  # sampled blind.
  describe "the face for having acted" do
    # Picked without reading a word of the reply, so it has to be mild enough
    # to sit under any sentence a completed action could produce. A laugh, a
    # starstruck gaze or a cheeky wink is a claim about the moment, and a dice
    # roll can't make one.
    it "never reaches for a face too strong to be picked blind" do
      strong = Buddy::VoiceLines::ACTED_MOODS.values.flat_map { |s| s[:ok] } &
        %i[uwu star excited grin wink crying]

      expect(strong).to be_empty
    end

    it "wears the miss when the turn didn't land" do
      20.times { expect(described_class.acted_mood(:byte, ok: false)).to be_in(%i[annoyed sad]) }
    end

    it "wears something pleased when it did" do
      20.times { expect(described_class.acted_mood(:byte)).to be_in(%i[happy nerd encouraging]) }
    end
  end
end

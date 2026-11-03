require "rails_helper"

# A routine tapped on the Quick grid or the kiosk runs with no model behind it,
# so the line over it is ours to write. The words are per-pet, and each line carries the FACE that goes with it:
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
    # A face is an image file: a line asking for one this pet can't render would
    # leave the pet blank, or resting on a transitional face.
    it "only asks each theme for faces it can wear, never the default", :aggregate_failures do
      Buddy::VoiceLines.table.each { |theme, kinds|
        lines = kinds.values.flatten

        expect(lines.reject { |line| Buddy::Faces.selectable?(theme, line[:mood]) }).to eq([]), theme.to_s
        expect(lines.select { |line| line[:mood] == Buddy::Faces.default }).to eq([]), theme.to_s
      }
    end

    # These lines carry their face directly rather than going through
    # Buddy::Sentiment, so Faces::NOT_A_CONFIRMATION has to hold here too.
    # Tiko's `nerd` art is a spellbook and a routine is a spell cast from it,
    # so its routine lines may wear it.
    it "does not blush or put its glasses on over something finished", :aggregate_failures do
      Buddy::VoiceLines.table.each { |theme, kinds|
        cast  = theme.to_sym == :tiko ? [] : Array(kinds[:routine_run]).pluck(:mood)
        moods = cast + Array(kinds[:chore_done]).pluck(:mood)

        expect(moods & Buddy::Faces::NOT_A_CONFIRMATION).to eq([]), theme.to_s
      }
    end

    # Per kind, not per theme: a line appearing twice in one set has double the odds.
    it "says each line once within a kind", :aggregate_failures do
      Buddy::VoiceLines.table.each { |theme, kinds|
        kinds.each { |kind, of_kind|
          expect(of_kind.pluck(:say).tally.select { |_say, n| n > 1 }).to eq({}), "#{theme} #{kind}"
        }
      }
    end

    it "gives every theme a line for every kind, and names the chore in every chore_done line", :aggregate_failures do
      kinds = Buddy::VoiceLines.table.values.flat_map(&:keys).uniq
      Buddy::Themes.all.each_key { |theme|
        kinds.each { |kind| expect(described_class.lines_for(theme, kind)).to be_present, "#{theme} #{kind}" }
      }
      Buddy::VoiceLines.table.each { |theme, of_theme|
        unnamed = of_theme[:chore_done].reject { |line| line[:say].include?("%<name>s") }

        expect(unnamed).to eq([]), "#{theme} has a chore_done line that doesn't say which chore"
      }
    end

    # The fallback only fires when Turn decides a hello is missing, so a
    # greeting the same check can't recognise would get a SECOND hello.
    it "writes greetings that read as greetings" do
      greetings = Buddy::VoiceLines.table.flat_map { |_theme, kinds|
        kinds.select { |kind, _| kind.to_s.start_with?("greeting_") }.values.flatten
      }

      expect(greetings).to be_present
      expect(greetings.reject { |line| line[:say].match?(Buddy::GPT::Turn::GREETING_OPENER_RX) }).to eq([])
    end
  end

  describe ".pick" do
    it "puts the routine's name in the line" do
      line = described_class.pick(:glimmer, :routine_run, name: "Yoga Lamp")

      expect(line[:text]).to include("Yoga Lamp")
      expect(line[:mood]).to be_present
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

    it "never reuses the line that opened the last one" do
      repeated = described_class.lines_for(:byte, :greeting_morning).first[:say]

      20.times {
        line = described_class.pick(:byte, :greeting_morning, unlike: "#{repeated} Quiet day today.")
        expect(line[:text]).not_to eq(repeated)
      }
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

    it "announces it in the pet's own voice and moves the face off neutral", :aggregate_failures do
      convo = convo!(:glimmer)
      said  = described_class.lines_for(:glimmer, :routine_run).map { |l| format(l[:say], name: "Yoga Lamp") }

      Buddy::Routines.run!(routine, conversation: convo)

      # The heading is the first line of the message; anything under it is the
      # steps reporting for themselves.
      expect(said).to include(convo.byte_messages.chronological.first.body.split("\n\n").first)
      expect(convo.reload.buddy_expression).to be_present
      expect(convo.buddy_expression).not_to eq(Buddy::Faces.default.to_s)
    end

    # The expression has to be there as the words land, not a beat behind them.
    # A routine is the one place the face is still chosen in Ruby rather than
    # read off the conversation — the line and its face are written together.
    it "sets the face before it posts the line" do
      convo = convo!(:glimmer)
      order = []
      allow(Buddy::ExpressionState).to receive(:wear) { order << :face }
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

  # The one face still chosen in Ruby: `wear` puts on a named one, and it is
  # what a routine's own line hands over. Everything conversational goes
  # through Buddy::Sentiment instead.
  describe Buddy::ExpressionState do
    before { allow(MonitorChannel).to receive(:broadcast_to) }

    it "wears a face this pet has" do
      convo = convo!(:glimmer)

      described_class.wear(convo, "grin")

      expect(convo.reload.buddy_expression).to eq("grin")
    end

    # `nerd` is Byte's, not Glimmer's; `thinking` is transitional, never a mood.
    it "refuses a face it cannot render, and the thinking face", :aggregate_failures do
      convo = convo!(:glimmer)

      described_class.wear(convo, "nerd")
      expect(convo.reload.buddy_expression).not_to eq("nerd")

      described_class.wear(convo, "thinking")
      expect(convo.reload.buddy_expression).not_to eq("thinking")
    end

    it "no-ops on no conversation at all" do
      expect { described_class.wear(nil, "grin") }.not_to raise_error
    end
  end
end

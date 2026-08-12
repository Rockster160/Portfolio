require "rails_helper"

# Prod 3332-3337, which was one failure wearing three faces.
#
# "That's actually more of a home one" refiled a stashed idea out of Work
# correctly, via the `sort_stash` side effect. Side effects are silent by
# design, so it left no chip and no row — the only trace was the sentence
# "Kk! Moved it to home." Told that was a lie, Buddy looked for evidence of its
# own doing, found none (that is exactly what `recent_actions` reads), agreed,
# and then invented a reason: "it's already in home, so there wasn't anything
# to move" — contradicting the Work receipt it had given five messages earlier.
# And it said all that twice, reworded in the middle, because the paragraph
# dedupe only caught byte-identical repeats.
#
# The design tension underneath: silence is RIGHT when an idea is first filed
# (the stash chip above it already says where it landed) and wrong when one is
# moved out of a bucket it was already in. Those had the same code path.
RSpec.describe "Buddy stash refile receipts" do
  let(:user) { create(:user) }
  let!(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }

  before { allow(MonitorChannel).to receive(:broadcast_to) }

  def chips
    convo.byte_messages.where("metadata->>'kind' = 'buddy_activity'").order(:created_at)
  end

  describe "moving one that was already filed" do
    let!(:idea) {
      user.buddy_ideas.create!(
        body: "recipe cards need total/prep/cook times", summary: "Recipe card time clarity",
        category: :work, status: :active
      )
    }

    it "really moves it" do
      Buddy::Stash.apply_sort(user, { id: idea.id, category: "home" }, conversation: convo)

      expect(idea.reload.category).to eq("home")
    end

    it "leaves a receipt naming where it went" do
      Buddy::Stash.apply_sort(user, { id: idea.id, category: "home" }, conversation: convo)

      expect(chips.count).to eq(1)
      expect(chips.last.body).to eq("Moved Recipe card time clarity to Home")
      expect(chips.last.metadata["tool_name"]).to eq("sort_stash")
    end

    # The chip is not decoration — `Buddy::Context#recent_actions` reads exactly
    # this, and the persona tells Buddy that anything missing from it did not
    # happen. That rule is what turned a silent success into a confession.
    it "shows up in the record Buddy checks when accused of not doing it" do
      Buddy::Stash.apply_sort(user, { id: idea.id, category: "home" }, conversation: convo)
      did = Buddy::Context.build(user, convo)[:recent_actions].pluck(:did)

      expect(did).to include("Moved Recipe card time clarity to Home")
    end

    it "reports that something changed, so a true claim survives the guard" do
      changed = Buddy::SideEffects.call(convo, :sort_stash, { id: idea.id, category: "home" })

      expect(changed).to be(true)
    end

    it "says nothing when it's already in that bucket" do
      Buddy::Stash.apply_sort(user, { id: idea.id, category: "work" }, conversation: convo)

      expect(chips.count).to eq(0)
    end
  end

  # Silence is correct here: Stash#capture! already posted "📥 Stashed to Home"
  # above this, and a second receipt saying the same thing is noise.
  describe "filing a fresh dump for the first time" do
    let!(:idea) { user.buddy_ideas.create!(body: "garage shelves", category: nil, status: :active) }

    it "files it silently" do
      Buddy::Stash.apply_sort(user, { id: idea.id, category: "home" }, conversation: convo)

      expect(idea.reload.category).to eq("home")
      expect(chips.count).to eq(0)
    end

    # The persona promises this one out loud: "Never announce that you're
    # updating it."
    it "sharpens a summary silently" do
      Buddy::Stash.apply_sort(user, { id: idea.id, summary: "Garage shelf plan" }, conversation: convo)

      expect(idea.reload.summary).to eq("Garage shelf plan")
      expect(chips.count).to eq(0)
    end

    it "still reports the change even with nothing to show" do
      expect(Buddy::SideEffects.call(convo, :sort_stash, { id: idea.id, category: "home" })).to be(true)
    end
  end

  describe "taking one off the pile" do
    let!(:idea) { user.buddy_ideas.create!(body: "uncover the tomatoes", category: :home, status: :active) }

    # It went somewhere it can be acted on. Buddy is told never to say a pile
    # entry is handled, so the chip says what actually happened to the ENTRY.
    it "leaves a receipt for that too" do
      Buddy::Stash.apply_sort(user, { id: idea.id, drop: true }, conversation: convo)

      expect(idea.reload.status).to eq("dropped")
      expect(chips.last.body).to eq("Took uncover the tomatoes off the pile")
    end
  end

  describe "when nothing is asked for" do
    let!(:idea) { user.buddy_ideas.create!(body: "something", category: :home, status: :active) }

    it "reports no change, so it can't back a claim" do
      expect(Buddy::SideEffects.call(convo, :sort_stash, { id: idea.id })).to be(false)
    end

    it "reports no change for an idea that isn't theirs" do
      expect(Buddy::SideEffects.call(convo, :sort_stash, { id: -1, category: "work" })).to be(false)
    end
  end

  # set_mood moves a face and nothing else. Letting it count as having acted
  # would hand every reply a free pass past the retraction guard, since Buddy
  # sets its mood on nearly all of them.
  describe "a side effect that changes nothing in the world" do
    it "does not report a change for set_mood" do
      expect(Buddy::SideEffects.call(convo, :set_mood, { expression: "happy" })).to be(false)
    end
  end

  # A conversation-level guard belongs with the paragraph dedupe it protects.
  describe "saying it twice" do
    subject(:deduped) {
      Buddy::GPT::Turn.new(
        convo.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: "hi"),
        client: FakeBuddyClient.new([]),
      ).send(:display_body, body)
    }

    context "when the second copy is reworded in the middle" do
      let(:body) {
        "Ahh, yep. You're right - it's still sitting in home already, so there wasn't anything " \
          "to move. The recipe card one is home now.\n\nAhh, yep. You're right - it's already in " \
          "home, so there wasn't anything to move. The recipe card one is home now."
      }

      it "keeps one of them" do
        expect(deduped.scan(/Ahh, yep/).size).to eq(1)
      end
    end

    context "when two paragraphs genuinely say different things" do
      let(:body) {
        "The recipe card one is in home now, so it'll come up with the house stuff.\n\n" \
          "Want me to pull the other two out of work while I'm in there, or leave those?"
      }

      it "keeps both" do
        expect(deduped.split("\n\n").size).to eq(2)
      end
    end

    # Short replies are mostly stock phrases and would collide constantly under
    # a similarity test. Below the floor, only an exact repeat is a repeat.
    context "when two short paragraphs are similar but not the same" do
      let(:body) { "Okie!\n\nOk!" }

      it "keeps both" do
        expect(deduped.split("\n\n").size).to eq(2)
      end
    end

    context "when a long paragraph is repeated word for word" do
      let(:body) { "Moved it over to home for you, that's where the rest of the house stuff lives.\n\n" * 2 }

      it "keeps one" do
        expect(deduped.split("\n\n").size).to eq(1)
      end
    end
  end
end

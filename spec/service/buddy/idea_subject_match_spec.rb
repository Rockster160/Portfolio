require "rails_helper"

# Prod 3350. "What were the buttons I wanted to add to Whisper's app?" was
# answered "Lights, playlist, projector, and a big mode button" — which is idea
# 37, stashed three hours earlier, whose summary reads "Glimmer iPad controls"
# and whose body opens "Glimmer iPad idea". Whisper is the dog. There is no
# stashed idea about a Whisper app at all.
#
# The question named a subject and the answer matched a shape: one held idea
# was about buttons, so it became the answer to a question about buttons. The
# right answer was the one Buddy gave on the retry — nothing on Whisper, and
# here's what the buttons one actually was.
#
# `search_ideas` already tells the model that nothing matching IS the answer.
# The list carried in every prompt said nothing of the kind, and that list is
# where this was answered from — no tool was called on the turn at all.
RSpec.describe "Buddy held-idea subject matching" do
  let(:user) { create(:user) }

  def block
    Buddy::Personality.open_loops_block(user)
  end

  before do
    user.buddy_ideas.create!(
      body:     "Glimmer iPad idea: control lights, playlist, projector, big button for mode",
      summary:  "Glimmer iPad controls",
      category: :home,
      status:   :active,
    )
  end

  it "tells the model the named thing has to be in the idea" do
    expect(block).to match(/the name has to actually be in the idea/i)
  end

  it "carries the case that broke it" do
    expect(block).to include("Whisper", "Glimmer")
  end

  it "says a near miss is worse than no answer" do
    expect(block).to match(/if the closest thing you hold names something else, that is the answer/i)
  end

  it "points at search_ideas, which answers a miss the same way" do
    expect(block).to include("search_ideas")

    tool  = Buddy::Tools[:search_ideas]
    empty = tool[:execute].call({ query: "whisper app buttons" }, Buddy::ToolContext.new(user))

    expect(empty[:ideas]).to be_empty
    expect(empty[:how]).to match(/nothing matched, and that IS the answer/i)
  end

  # The subject is only checkable if it's on the line. A summary is what the
  # block prints, so a summary that drops the subject would hide it again.
  it "prints the idea's own summary, which names its subject" do
    expect(block).to include("Glimmer iPad controls")
  end

  it "costs nothing for someone holding no ideas" do
    expect(Buddy::Personality.open_loops_block(create(:user))).to be_nil
  end
end

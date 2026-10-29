require "rails_helper"

# "Both views should also have a search." Half an hour of talking is 120 turns,
# and what gets asked of a recording afterwards is nearly always a lookup: what
# did they ask about testing, what did I say about money. One module does it in
# both places a conversation is read — its own page, and the beat it hangs off
# in the timeline.
RSpec.describe "Transcript search (JS-side)" do
  let(:result) {
    JsRunner.output("spec/javascript/transcript_search_runner.js", symbolize: true)
  }

  it "wires the pane the page actually has" do
    expect(result[:wired]).to eq(1)
  end

  # Non-matching turns go away rather than being scrolled past: both lists are
  # already scrollers, so what is wanted is the lines that mention the thing
  # sitting next to each other.
  it "keeps only the turns that say it" do
    expect(result[:forWords][:shown]).to eq(2)
    expect(result[:forWords][:count]).to eq("2 of 4")
  end

  it "lights the words up where they were said" do
    expect(result[:markedUp]).to eq("I would rather have the argument <mark>early</mark>.")
  end

  # "What did the recruiter say" is the same question as "what was said about
  # the salary", so the speaker is searched along with the words.
  it "finds a turn by who was speaking" do
    expect(result[:forName][:shown]).to eq(2)
  end

  # An empty list and a transcript that never loaded look identical, so the
  # count is the only thing that can say a search found nothing.
  it "says plainly when nobody said it" do
    expect(result[:forNothing][:shown]).to eq(0)
    expect(result[:forNothing][:count]).to eq("nothing says that")
  end

  it "puts the whole conversation back when the box is emptied" do
    expect(result[:cleared][:shown]).to eq(4)
    expect(result[:cleared][:count]).to eq("4 turns")
    expect(result[:clearedMarkup]).to eq("I would rather have the argument early.")
  end

  # A filtered list with the box scrolled out of sight reads as a transcript
  # that lost most of itself.
  it "empties on escape, from inside the box" do
    expect(result[:afterEscape][:value]).to eq("")
    expect(result[:afterEscape][:shown]).to eq(4)
  end

  # The mark goes in as HTML, so anything in the words that looks like a tag has
  # to come back out as text. A recorder writes what it hears, and what it hears
  # is sometimes "less than".
  it "lights up words that hold angle brackets without running them" do
    expect(result[:escapesTheWords]).to eq(
      "How do you handle &lt;em&gt;<mark>disagreeing</mark>&lt;/em&gt; with a teammate?",
    )
  end
end

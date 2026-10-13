require "rails_helper"

RSpec.describe TranscriptParser do
  # The shape a meeting recorder actually writes: one cue per few words, each
  # with its own timestamp, the speaker guessed at and repeated on every line.
  let(:cues) {
    <<~VTT
      11:59:55 --> 11:59:57
      Speaker 1: Well,

      11:59:57 --> 12:00:02
      Speaker 1: thanks so much for joining us today.

      12:00:02 --> 12:00:06
      Speaker 2: Yeah,

      12:00:06 --> 12:00:09
      Speaker 2: happy to be here.
    VTT
  }

  it "gathers the captions of one speaker into a turn" do
    turns = described_class.call(cues)

    expect(turns.length).to eq(2)
    expect(turns.first["text"]).to eq("Well, thanks so much for joining us today.")
    expect(turns.first["raw"]).to eq("Speaker 1")
    expect(turns.last["text"]).to eq("Yeah, happy to be here.")
  end

  it "carries the start of the first caption and the end of the last" do
    turns = described_class.call(cues)

    expect(turns.first["at"]).to eq((11 * 3600) + (59 * 60) + 55)
    expect(turns.first["to"]).to eq((12 * 3600) + 2)
  end

  # `raw` is what the machine said and `speaker` is who it turned out to be.
  # They start equal, and only the second one is ever edited.
  it "starts every turn assigned to the label it was transcribed under" do
    turns = described_class.call(cues)

    expect(turns.pluck("speaker")).to eq(turns.pluck("raw"))
  end

  # A label can sit unchanged across a handover - the recorder simply does not
  # notice. A long silence is the one signal left that somebody else started.
  it "breaks a turn where the same label goes quiet for longer than the gap" do
    text = <<~VTT
      00:00:01 --> 00:00:03
      Unknown: So that is the role.

      00:00:30 --> 00:00:33
      Unknown: Thanks, that makes sense.
    VTT

    turns = described_class.call(text)

    expect(turns.length).to eq(2)
  end

  # Some exporters write nothing but the lines. Recognised by there being no
  # arrow in the file at all, because nobody knows which tool made the file
  # they are dropping in.
  it "reads a file that has names and no timestamps" do
    text = <<~TEXT
      Casey Holm: How do you handle disagreeing with a teammate?
      Rocco: I would rather have the argument early.
      It is cheaper than finding out in review.
    TEXT

    turns = described_class.call(text)

    expect(turns.pluck("raw")).to eq(["Casey Holm", "Rocco"])
    expect(turns.last["text"]).to eq(
      "I would rather have the argument early. It is cheaper than finding out in review.",
    )
    expect(turns.first["at"]).to be_nil
  end

  # A colon inside a sentence is not somebody's name, and reading it as one
  # would invent a speaker per sentence.
  it "does not mistake a colon in a sentence for a speaker" do
    text = <<~VTT
      00:00:01 --> 00:00:04
      There was one thing: it never worked.
    VTT

    turns = described_class.call(text)

    expect(turns.first["raw"]).to eq("Unknown")
    expect(turns.first["text"]).to eq("There was one thing: it never worked.")
  end

  it "joins a caption that was written over several lines" do
    text = <<~VTT
      00:00:01 --> 00:00:06
      Speaker 1: I ran the migration
      a record type at a time.
    VTT

    expect(described_class.call(text).first["text"])
      .to eq("I ran the migration a record type at a time.")
  end

  it "names the speakers in the order they first talk" do
    turns = described_class.call(cues)

    expect(described_class.speakers_in(turns)).to eq(["Speaker 1", "Speaker 2"])
  end

  it "comes back with nothing for a file that holds nothing" do
    expect(described_class.call("")).to eq([])
  end
end

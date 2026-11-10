require "rails_helper"

# The readable version of notes he typed during a call, written beside them.
#
# The examples here are mostly about what it REFUSES, and the thing being
# refused is the opposite of the one `Transcripts::Clean` guards against.
# There, the words were spoken and the risk is a model improving them. Here the
# words were typed in shorthand and rewriting them IS the job - so what can go
# wrong is invention: a fifth point that sounds right under four that were
# actually made, or a number quietly rounded in a sentence that now reads well.
RSpec.describe Notes::Clean do
  let(:user) { User.me }
  let(:job) { user.job_applications.create!(company: "Podium", role: "Staff Engineer") }

  # Shorthand, with the two things the guards exist to protect: a figure that
  # appears nowhere else in it, and a link.
  def typed
    <<~NOTES.strip
      System Design Interview
        Podium: Building a product for the customer
        45 min interview
        2 prong: 1 Conversation 2 Design
        Coder Pad - whiteboard style
        Tips:
          1. WWhen given prompt, do NOT just jump in. ASK QUESTIONS.
          2. MOST SIMPLISITIC DESIGN POSSIBLE
        Zoom: https://podium.zoom.us/j/91793913798
    NOTES
  end

  def model_says(text)
    allow_any_instance_of(Buddy::GPT::Client).to receive(:stream) { |_client, args|
      asked << args[:instructions].to_s
      { ok: true, text: text, model: "gpt-5.4-mini", usage: FakeBuddyClient::DEFAULT_USAGE }
    }
  end

  def asked = (@asked ||= [])

  def note!(body: typed, tag: :recruiter_call, **attrs)
    job.notes.create!(tag: tag, occurred_at: 1.hour.ago, body: body, **attrs)
  end

  # Long enough to clear the floor and keeping both numbers and the link, so it
  # is the version every guard is meant to let through.
  def written
    <<~TEXT.strip
      **System Design Interview**

      Podium builds a product for the customer. It is a 45 min interview with
      2 prongs: a conversation and a design, held in Coder Pad in whiteboard
      style.

      Tips:

      1. When given the prompt, do not just jump in. Ask questions.
      2. The most simplistic design possible.

      Zoom: https://podium.zoom.us/j/91793913798
    TEXT
  end

  it "writes a readable version and leaves what he typed alone" do
    model_says(written)
    note = note!

    result = described_class.call(note)

    expect(result.ok).to be(true)
    expect(note.reload.clean_body).to include("do not just jump in")
    expect(note.cleaned_at).to be_present
    expect(note.body).to eq(typed)
  end

  it "hands the model what kind of beat it was and who was in it" do
    model_says(written)
    note = note!(spoke_to: "Tyler Mills")

    described_class.call(note)

    expect(asked.first).to include("Tyler Mills", "Podium")
  end

  it "reads the readable version and keeps the typed one a tap away" do
    model_says(written)
    note = note!

    described_class.call(note)

    expect(note.reload.reading).to include("do not just jump in")
    expect(note.reading(clean: false)).to eq(typed)
  end

  it "refuses a version that dropped one of his numbers" do
    model_says(written.sub("45 min", "three quarters of an hour"))
    note = note!

    result = described_class.call(note)

    expect(result.ok).to be(false)
    expect(result.error).to eq(:refused)
    expect(note.reload.clean_body).to be_nil
  end

  it "refuses a version that dropped the link" do
    model_says(written.sub("https://podium.zoom.us/j/91793913798", "the Zoom room"))
    note = note!

    expect(described_class.call(note).error).to eq(:refused)
    expect(note.reload.clean_body).to be_nil
  end

  it "refuses a version that grew into an essay" do
    model_says("#{written}\n\n#{"Garrett will likely ask about scaling. " * 60}")
    note = note!

    expect(described_class.call(note).error).to eq(:refused)
    expect(note.reload.clean_body).to be_nil
  end

  it "refuses a version that lost most of what he wrote" do
    model_says("System design interview, 1hr, 2 prongs. https://podium.zoom.us/j/91793913798")
    note = note!

    expect(described_class.call(note).error).to eq(:refused)
    expect(note.reload.clean_body).to be_nil
  end

  it "says nothing about a beat that is already one readable line" do
    model_says(written)
    note = note!(body: "Thanked Clarissa for the confirmation.")

    expect(described_class.call(note).error).to eq(:short)
    expect(note.reload.clean_body).to be_nil
  end

  it "does not do it twice unless it is asked twice" do
    model_says(written)
    note = note!
    described_class.call(note)
    note.update!(clean_body: "the version he fixed himself")

    expect(described_class.call(note).error).to eq(:done)
    expect(note.reload.clean_body).to eq("the version he fixed himself")
  end

  it "overwrites his own edit when the press asks for it" do
    model_says(written)
    note = note!
    described_class.call(note)
    note.update!(clean_body: "the version he fixed himself")

    expect(described_class.call(note, again: true).ok).to be(true)
    expect(note.reload.clean_body).to include("do not just jump in")
  end
end

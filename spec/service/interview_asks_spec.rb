require "rails_helper"

# "I got an availability check from Podium which included notes of what to
# prepare." The mail that books an interview often says what the interview is,
# and it was sitting in the middle of a beat nobody read for that.
RSpec.describe InterviewAsks do
  let(:user) { User.me }
  let(:job) { user.job_applications.create!(company: "Podium", role: "Senior Software Engineer") }

  # The Podium mail, as it arrived - every paragraph of it, because which
  # paragraphs are an ask and which are pleasantries is the whole question.
  let(:availability) {
    <<~MAIL
      Hi Rocco,

      Thanks for your interest in Podium's GTM, Senior Software Engineer opportunity. Our team is excited to move you forward to the next step, a 30-minute Zoom interview with the hiring manager, Evelyn Sharp.

      To make the most of this conversation, come ready to walk through:

      * An AI system you've built or shipped that takes action (tools, multi-step workflows, or agents), and how you measured its quality.
      * A product decision you owned, and its impact for external customers or internal stakeholders.
      * A time you disagreed with a teammate or stakeholder, what you did next, and lessons learned.

      This role is onsite in our Lehi, Utah office, Monday through Friday.

      I've copied my colleague, Clarissa, who will manage the logistics. Please submit your availability via the calendar link here: Enter your availability now > ( https://app.greenhouse.io/availability/9e04dec2 )

      In the meantime, I highly recommend reviewing our Operating Principles ( https://www.podium.com/operating-principles/ ) to get a sense of how we build at Podium.

      Looking forward to the next steps!

      Regards,

      Tyler Mills
    MAIL
  }

  describe ".passages" do
    it "takes the instruction and the list under it, which is the whole ask" do
      found = described_class.passages(availability)

      expect(found.first).to include("come ready to walk through")
      expect(found.first).to include("An AI system you've built or shipped")
      expect(found.first).to include("A time you disagreed with a teammate")
    end

    # The bullets ARE the ask. A cue carried without them says somebody asked
    # for something and not what.
    it "leaves the pleasantries behind it out" do
      found = described_class.passages(availability).first

      expect(found).not_to include("Thanks for your interest")
      expect(found).not_to include("This role is onsite")
      expect(found).not_to include("Tyler Mills")
    end

    # Something to go and read before the call is an ask as much as a story to
    # have ready, and it is the half that needs the most notice.
    it "takes the reading they recommended as an ask of its own" do
      found = described_class.passages(availability)

      expect(found.size).to eq(2)
      expect(found.last).to include("reviewing our Operating Principles")
    end

    # The link line and the sign-off. Neither asks for anything, and both sit
    # next to something that does.
    it "takes neither the scheduling link nor the sign-off" do
      found = described_class.passages(availability).join("\n")

      expect(found).not_to include("Enter your availability now")
      expect(found).not_to include("Looking forward to the next steps")
    end

    it "finds nothing in a mail that asks for nothing" do
      expect(described_class.passages("Thanks for applying. We will be in touch.")).to be_empty
    end

    # The sign-off every ATS writes. Read as an ask it would donate a paragraph
    # of boilerplate to every brief.
    it "is not tripped by a mail that only mentions the process in passing" do
      said = "We will be in touch about the interview process once the team has reviewed."

      expect(described_class.passages(said)).to be_empty
    end

    # The other shape: the whole process in one mail, with a line under each
    # round saying what it covers.
    it "takes a numbered rundown of the rounds" do
      found = described_class.passages(
        <<~MAIL,
          Hi Rocco,

          Here is what to expect from our process:

          1. A 30 minute recruiter screen with me.
          2. A technical screen - one hour, live coding in a language of your choice.
          3. An onsite loop with four engineers and the hiring manager.

          Let me know if you have questions.
        MAIL
      )

      expect(found.size).to eq(1)
      expect(found.first).to include("live coding in a language of your choice")
      expect(found.first).to include("onsite loop with four engineers")
    end

    # "the process is as follows:" and then a sentence saying what it is - no
    # list to find, and the colon is what says the next paragraph is the answer.
    it "takes the paragraph under a line that ended on a colon" do
      found = described_class.passages(
        <<~MAIL,
          Our process is as follows:

          Two conversations, both remote, a week apart.

          Thanks,
        MAIL
      )

      expect(found.first).to include("Two conversations, both remote")
      expect(found.first).not_to include("Thanks")
    end

    it "keeps one passage from running away with the prompt" do
      found = described_class.passages("Please prepare the following:\n\n#{"* a thing\n" * 400}")

      expect(found.first.length).to be <= described_class::MAX_SAID
    end
  end

  describe ".for" do
    # EVERY beat, not the recent ones. The rundown is the first mail and the
    # round it describes is booked a month and thirty beats later.
    it "reaches back past the newest beats to the one that said it" do
      job.notes.create!(
        tag:         :recruiter_call,
        occurred_at: 40.days.ago,
        body:        "Here is what to expect:\n\n* A technical screen, one hour of live coding.",
      )
      12.times do |index|
        job.notes.create!(tag: :note, occurred_at: index.days.ago, body: "Nothing in particular.")
      end

      found = described_class.for(job)

      expect(found.size).to eq(1)
      expect(found.first.said).to include("live coding")
    end

    it "says which round each one is about" do
      job.notes.create!(tag: :availability, occurred_at: 1.day.ago, body: availability)

      found = described_class.for(job)

      expect(found.first.rounds).to eq([:manager])
      expect(found.first.round_labels).to include("Hiring manager interview")
      expect(found.first).to be_about(:manager)
    end

    it "reads them oldest first, which is the order a process gets explained" do
      job.notes.create!(
        tag:         :recruiter_call,
        occurred_at: 9.days.ago,
        body:        "What to expect: a recruiter screen, then a panel.",
      )
      job.notes.create!(tag: :availability, occurred_at: 1.day.ago, body: availability)

      expect(described_class.for(job).map { |ask| ask.said[0, 12] })
        .to eq(["What to expe", "To make the ", "In the meant"])
    end

    # Which of four asks is about the hour coming up. The calendar row names the
    # round too, and an ask whose round it also names is the one that matters.
    it "marks the ask the booking itself is about" do
      job.notes.create!(tag: :availability, occurred_at: 1.day.ago, body: availability)
      job.notes.create!(
        tag:         :recruiter_call,
        occurred_at: 9.days.ago,
        body:        "Be prepared to talk salary on the recruiter screen.",
      )
      item = AgendaItem.new(name: "Podium - hiring manager interview", notes: "Zoom")

      found = described_class.for(job, event: item)

      manager = found.find { |ask| ask.about?(:manager) }
      recruiter = found.find { |ask| ask.about?(:recruiter) && !ask.about?(:manager) }
      expect(manager.fits_event).to be(true)
      expect(recruiter.fits_event).to be(false)
    end

    it "marks none of them when the booking says nothing about which round it is" do
      job.notes.create!(tag: :availability, occurred_at: 1.day.ago, body: availability)
      item = AgendaItem.new(name: "Interview", notes: nil)

      expect(described_class.for(job, event: item).map(&:fits_event)).to all(be(false))
    end

    it "finds nothing on an application nobody has told anything" do
      job.notes.create!(tag: :applied, occurred_at: 2.days.ago, body: "Applied through the site.")

      expect(described_class.for(job)).to be_empty
    end
  end
end

require "rails_helper"

RSpec.describe InterviewPrep do
  let(:user) { create(:user) }
  let(:job) { user.job_applications.create!(company: "Bluestaq") }

  describe ".from_report" do
    let(:report) {
      <<~MD
        # Technical screen with Bluestaq
        KIND: technical

        ## The company
        They build data platforms for the Space Force.

        ## What to go over
        - Ruby's Enumerable, specifically lazy
      MD
    }

    it "takes the title off the top so the page has a real heading" do
      prep = described_class.from_report(report, job_application: job)

      expect(prep.title).to eq("Technical screen with Bluestaq")
    end

    it "takes the kind, which is what the heading and the push say it is" do
      prep = described_class.from_report(report, job_application: job)

      expect(prep.kind).to eq("technical")
      expect(prep.kind_label).to eq("Technical interview")
    end

    # Both lines became columns. Left in the body they are a heading repeated
    # under itself and a stray `KIND:` line in the middle of the prose.
    it "keeps them out of the body" do
      prep = described_class.from_report(report, job_application: job)

      expect(prep.body).to start_with("## The company")
      expect(prep.body).not_to include("KIND:")
    end

    it "keeps the rest exactly as it was written" do
      prep = described_class.from_report(report, job_application: job)

      expect(prep.body).to include("- Ruby's Enumerable, specifically lazy")
    end

    # A brief that forgot its opening lines is still the brief. Refusing it, or
    # guessing a kind out of the prose, loses the research over formatting.
    it "survives a report with no opening lines at all" do
      prep = described_class.from_report("## The company\nThey build things.", job_application: job)

      expect(prep.title).to be_nil
      expect(prep.kind).to be_nil
      expect(prep.body).to include("They build things.")
    end

    # `unknown` is the session saying it could not tell, which is not a kind.
    # Stored as one it would caption the page "Unknown interview".
    it "reads `unknown` as nothing rather than as a kind" do
      prep = described_class.from_report("# A call\nKIND: unknown\n\nbody", job_application: job)

      expect(prep.kind).to be_nil
      expect(prep.label).to eq("Bluestaq")
    end

    # A `# heading` deep in the brief is a heading. Only the opening window is
    # read for these, or the first section title becomes the page title.
    it "leaves a heading further down the report alone" do
      body = ([""] * 8).join("\n") + "# Anything odd\nThe recruiter went quiet.\n"
      prep = described_class.from_report("# Real title\nKIND: panel\n#{body}", job_application: job)

      expect(prep.title).to eq("Real title")
      expect(prep.body).to include("# Anything odd")
    end

    it "takes a kind it does not know as the session said it" do
      prep = described_class.from_report("# A call\nKIND: pairing\n\nbody", job_application: job)

      expect(prep.kind).to eq("pairing")
      expect(prep.kind_label).to eq("Pairing")
    end
  end

  describe "when the interview is" do
    it "is upcoming while it is still ahead" do
      prep = job.preps.new(body: "x", interview_at: 1.hour.from_now)

      expect(prep).to be_upcoming
      expect(prep).not_to be_spent
    end

    it "is spent once it has happened" do
      prep = job.preps.new(body: "x", interview_at: 1.hour.ago)

      expect(prep).to be_spent
      expect(prep).not_to be_upcoming
    end

    # Asked for by hand, with nothing counting down to it. Neither state is
    # true, and the page says the day it was written instead.
    it "is neither when nobody said" do
      prep = job.preps.new(body: "x")

      expect(prep).not_to be_spent
      expect(prep).not_to be_upcoming
    end
  end
end

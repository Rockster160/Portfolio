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

    # The title and kind become columns, so they come out of the body and the
    # rest is kept as written.
    it "lifts the title and kind off the top and keeps the rest as written", :aggregate_failures do
      prep = described_class.from_report(report, job_application: job)

      expect(prep.title).to eq("Technical screen with Bluestaq")
      expect(prep.kind).to eq("technical")
      expect(prep.body).to start_with("## The company")
      expect(prep.body).not_to include("KIND:")
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
    end
  end

  describe "when the interview is" do
    # Asked for by hand, with nothing counting down to it, is neither.
    it "is upcoming while ahead, spent once past, and neither with no time", :aggregate_failures do
      [[1.hour.from_now, true, false], [1.hour.ago, false, true], [nil, false, false]].each do |at, upcoming, spent|
        prep = job.preps.new(body: "x", interview_at: at)

        expect(prep.upcoming?).to eq(upcoming), "upcoming? at #{at.inspect}"
        expect(prep.spent?).to eq(spent), "spent? at #{at.inspect}"
      end
    end
  end
end

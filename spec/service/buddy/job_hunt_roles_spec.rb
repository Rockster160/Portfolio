require "rails_helper"

# Two failures from 15 Sep, both of them `resolve_application` knowing only a
# company name.
RSpec.describe Buddy::JobHunt do
  let(:user) { create(:user) }

  def application(company, role)
    JobApplication.create!(user: user, company: company, role: role)
  end

  # Prod: he applied to three separate Aledade PBC roles in one day and all
  # three landed on application 28.
  describe ".role_named_in?" do
    let(:job) { application("Aledade PBC", "Principal Engineer - AI Data and Infrastructure") }

    it "says no to a headline naming another role at the same company" do
      said = "Application received for Senior Software Engineer I- Fullstack"

      expect(described_class.role_named_in?(job, said)).to be(false)
    end

    it "says yes when the row's own role is what arrived" do
      said = "Application received for Principal Engineer - AI Data and Infrastructure"

      expect(described_class.role_named_in?(job, said)).to be(true)
    end

    # "Engineer" alone is shared by nearly every row on the board, so a thin
    # overlap must not read as a match.
    it "is not satisfied by one word in common" do
      expect(described_class.role_named_in?(job, "Update on your Engineer application")).to be(false)
    end

    # An ATS headline abbreviates. Half the role is enough to be that job, and
    # refusing this would send a correct note to a brand new application.
    it "accepts the role with its tail cut off" do
      said = "Application received for Principal Engineer"

      expect(described_class.role_named_in?(job, said)).to be(true)
    end

    # The other direction has no company to check against, so it asks for all
    # of it: two thirds of a role is a different role.
    it "does not pick a row off a partial role when that is all it has" do
      said = "Application received for Principal Engineer"

      expect(described_class.role_named_in?(job, said, ratio: described_class::WHOLE_ROLE)).to be(false)
    end

    # Unanswerable, not false-negative-by-accident: a row with no role recorded
    # cannot be checked, and the caller treats that as "don't refuse".
    it "says no when the row has no role at all" do
      bare = application("Someone", nil)

      expect(described_class.role_named_in?(bare, "anything")).to be(false)
    end
  end

  # Prod email 51716: a Greenhouse receipt naming a role and no company. Twelve
  # minutes later jobhunt opened the row for that exact role, and the two never
  # met.
  describe ".resolve_by_role" do
    before { application("Fieldwire by Hilti", "Senior Backend Engineer") }

    it "finds the row a company-less mail is about" do
      hit = described_class.resolve_by_role(user, "Application received for Senior Backend Engineer position")

      expect(hit&.company).to eq("Fieldwire by Hilti")
    end

    it "stays out of it when two rows could both be meant" do
      application("Other Co", "Senior Backend Engineer")

      expect(described_class.resolve_by_role(user, "Application received for Senior Backend Engineer")).to be_nil
    end

    # Two words of three in common, and a different job.
    it "does not mistake a neighbouring role for this one" do
      hit = described_class.resolve_by_role(user, "Application received for Senior Frontend Engineer")

      expect(hit).to be_nil
    end

    it "returns nothing when no role on the board is named" do
      expect(described_class.resolve_by_role(user, "Thank you for your interest in joining our team")).to be_nil
    end

    # Prod 51932, 1 Oct. A Workday "verify your candidate account" mail named
    # Motorola Solutions, whose row jobhunt did not open until ten minutes
    # later. Its headline named a "Software Engineer application" and the only
    # row whose whole role is "Software Engineer" was Shopify's, weeks old. The
    # note was filed there in Ruby and the briefing announced Shopify.
    #
    # Containment runs backwards as the title gets more ordinary: the generic
    # one is the EASIEST to name in full, so it wins the most mail. The test is
    # a word of its own - a word two rows share cannot tell them apart, and a
    # title built only from shared words tells nothing apart.
    describe "a role with no word of its own" do
      # The board around it, which is what makes "software" and "engineer"
      # ordinary. On the real one, engineer is on 76 rows of 98 and software on
      # 37.
      before {
        application("ApartmentIQ", "Senior Software Engineer")
        application("Symetra", "Staff Software Engineer")
        application("Machinify", "Software Architect")
      }

      it "refuses a generic title, however exactly it is named" do
        application("Shopify", "Software Engineer")

        hit = described_class.resolve_by_role(user, "Verify candidate account for Software Engineer application")

        expect(hit).to be_nil
      end

      # The one the fallback was built for. "generative" is on one row and
      # nothing else, which is the whole of what makes the role a handle - and
      # it holds with "AI" dropped for being two letters, where counting words
      # would not.
      it "still takes a role that owns one of its words" do
        application("Peregrine Advisors", "Generative AI Engineer")

        hit = described_class.resolve_by_role(user, "Application received for Generative AI Engineer")

        expect(hit&.company).to eq("Peregrine Advisors")
      end
    end
  end

  # Two rows at one company, and SAME_ROLE clears both on seniority and
  # discipline alone.
  describe ".resolve_application with several rows at one company" do
    let!(:meant) { application("Oracle", "Lead Principal Platform Software Engineer") }
    let!(:other) { application("Oracle", "Sr Lead Software Engineer - Agentic AI Engineer") }

    it "takes the row the text names in full" do
      said = "Application received for Lead Principal Platform Software Engineer We received your application"

      expect(described_class.resolve_application(user, "Oracle", said: said)).to eq(meant)
    end

    it "still stands back when the text names both of them whole" do
      application("Oracle", "Lead Principal Platform Software Engineer II")
      said = "Lead Principal Platform Software Engineer II"

      expect(described_class.resolve_application(user, "Oracle", said: said)).to be_nil
    end

    it "still stands back when the text names neither of them whole" do
      said = "Application received for Lead Software Engineer"

      expect(described_class.resolve_application(user, "Oracle", said: said)).to be_nil
    end
  end
end

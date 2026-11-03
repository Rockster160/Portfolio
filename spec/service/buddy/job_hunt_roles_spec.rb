require "rails_helper"

# Telling one application from another when the mail names a role, at a company
# with several rows on the board or with no company at all.
RSpec.describe Buddy::JobHunt do
  let(:user) { create(:user) }

  def application(company, role)
    JobApplication.create!(user: user, company: company, role: role)
  end

  describe ".role_named_in?" do
    let(:job) { application("Aledade PBC", "Principal Engineer - AI Data and Infrastructure") }

    it "matches the row's own role, abbreviated or whole, and nothing thinner", :aggregate_failures do
      [
        ["Application received for Principal Engineer - AI Data and Infrastructure", true],
        ["Application received for Senior Software Engineer I- Fullstack", false],
        # One word shared by nearly every row on the board is not a match.
        ["Update on your Engineer application", false],
        # An ATS headline abbreviates; half the role is enough to be that job.
        ["Application received for Principal Engineer", true],
      ].each do |said, expected|
        expect(described_class.role_named_in?(job, said)).to be(expected), said
      end
    end

    # The other direction has no company to check against, so it asks for all
    # of it: two thirds of a role is a different role.
    it "asks for the whole role when that is all it has" do
      said = "Application received for Principal Engineer"

      expect(described_class.role_named_in?(job, said, ratio: described_class::WHOLE_ROLE)).to be(false)
    end

    # Unanswerable: the caller treats that as "don't refuse".
    it "says no when the row has no role at all" do
      expect(described_class.role_named_in?(application("Someone", nil), "anything")).to be(false)
    end
  end

  describe ".resolve_by_role" do
    before { application("Fieldwire by Hilti", "Senior Backend Engineer") }

    it "finds the row a company-less mail is about, and not a neighbouring role", :aggregate_failures do
      hit = described_class.resolve_by_role(user, "Application received for Senior Backend Engineer position")
      expect(hit&.company).to eq("Fieldwire by Hilti")

      expect(described_class.resolve_by_role(user, "Application received for Senior Frontend Engineer")).to be_nil
      expect(described_class.resolve_by_role(user, "Thank you for your interest in joining our team")).to be_nil
    end

    it "stays out of it when two rows could both be meant" do
      application("Other Co", "Senior Backend Engineer")

      expect(described_class.resolve_by_role(user, "Application received for Senior Backend Engineer")).to be_nil
    end

    # A word two rows share cannot tell them apart, so a title built only from
    # shared words is refused however exactly it is named, and a role that owns
    # a word of its own is a handle.
    describe "a role with no word of its own" do
      before {
        application("ApartmentIQ", "Senior Software Engineer")
        application("Symetra", "Staff Software Engineer")
        application("Machinify", "Software Architect")
        application("Shopify", "Software Engineer")
        application("Peregrine Advisors", "Generative AI Engineer")
      }

      it "refuses a generic title and takes one that owns a word", :aggregate_failures do
        expect(described_class.resolve_by_role(user, "Verify candidate account for Software Engineer application")).to be_nil

        hit = described_class.resolve_by_role(user, "Application received for Generative AI Engineer")
        expect(hit&.company).to eq("Peregrine Advisors")
      end
    end
  end

  describe ".resolve_application with several rows at one company" do
    let!(:meant) { application("Oracle", "Lead Principal Platform Software Engineer") }
    let!(:other) { application("Oracle", "Sr Lead Software Engineer - Agentic AI Engineer") }

    it "takes the row the text names in full, and stands back when it names neither", :aggregate_failures do
      said = "Application received for Lead Principal Platform Software Engineer We received your application"
      expect(described_class.resolve_application(user, "Oracle", said: said)).to eq(meant)

      expect(described_class.resolve_application(user, "Oracle", said: "Application received for Lead Software Engineer")).to be_nil
    end

    it "stands back when the text names two of them whole" do
      application("Oracle", "Lead Principal Platform Software Engineer II")

      expect(described_class.resolve_application(user, "Oracle", said: "Lead Principal Platform Software Engineer II")).to be_nil
    end
  end
end

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
  end
end

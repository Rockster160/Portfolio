require "rails_helper"

RSpec.describe FeatureBuild do
  describe ".for_pull_request" do
    let(:build) { described_class.create!(user: User.me, title: "Dark mode", request: "dark mode") }

    it "finds the build its branch names, under either prefix" do
      expect(described_class.for_pull_request({ "head" => { "ref" => "byte/#{build.id}-dark-mode" } })).to eq(build)
      expect(
        described_class.for_pull_request({ "head" => { "ref" => "feature-builder/#{build.id}-dark-mode" } }),
      ).to eq(build)
    end

    it "falls back to the PR's number for a branch it doesn't recognize" do
      build.update!(pr_number: 7)

      expect(described_class.for_pull_request({ "head" => { "ref" => "other/1-x" }, "number" => 7 })).to eq(build)
    end
  end
end

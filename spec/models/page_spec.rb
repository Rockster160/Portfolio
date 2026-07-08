require "rails_helper"

RSpec.describe Page do
  describe "#to_packet" do
    let(:page) { create(:page) }

    it "reports deleted: false for a live record" do
      expect(page.to_packet[:deleted]).to eq(false)
    end

    it "reports deleted: true during the destroy after_commit" do
      captured = nil
      allow(PageChannel).to receive(:broadcast_to) { |_, payload| captured = payload }
      page.destroy!
      expect(captured[:changes].first[:deleted]).to eq(true)
      expect(captured[:changes].first[:id]).to eq(page.id)
    end
  end
end

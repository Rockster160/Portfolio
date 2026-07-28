require "rails_helper"

# The "Today" briefing bakes in a weather line + comfort guidance (only that
# action, not every message). weather_briefing_block is the pure string
# helper it uses.
RSpec.describe Buddy::QuickActionsController, type: :controller do
  let(:controller_instance) { described_class.new }

  describe "#weather_briefing_block" do
    it "injects the weather summary + comfort guidance when available" do
      allow(WeatherService).to receive(:summary)
        .and_return("currently 88°F, sunny. today high 92°F / low 64°F.")

      block = controller_instance.send(:weather_briefing_block)

      expect(block).to include("currently 88°F, sunny")
      expect(block).to include("comfortable sweet spot")
      expect(block).to match(/hot/)   # comfort framing present
    end

    it "is blank when weather is unavailable (dev/no key) so nothing is injected" do
      allow(WeatherService).to receive(:summary).and_return(nil)
      expect(controller_instance.send(:weather_briefing_block)).to eq("")
    end
  end
end

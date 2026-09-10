require "rails_helper"

# The guide is only worth having if it is TRUE, and the thing that makes it
# stop being true is an ordinary edit somebody makes months from now with no
# idea this file exists. So every control it claims is anchored to the `data-*`
# hook it is actually rendered with, and this checks each one is still in the
# markup. Rename a hook and this fails - which is the only version of "keep it
# up to date" that survives contact with a year of changes.
RSpec.describe Buddy::ScreenGuide do
  let(:view) { Rails.root.join("app/views/byte/show.html.erb").read }

  describe "the hooks it claims" do
    described_class::SURFACES.each do |surface|
      surface[:controls].each do |control|
        it "#{surface[:name]}: #{control[:hook]} is still in the markup" do
          expect(view).to include(control[:hook])
        end
      end
    end

    it "names each hook once, so no control is described twice" do
      expect(described_class.hooks.tally.select { |_hook, n| n > 1 }).to eq({})
    end
  end

  # The hook is the anchor, not the answer. A person asking what the bell does
  # is not helped by "data-byte-notify".
  describe ".for_user" do
    let(:user) { create(:user) }

    it "hands over labels and plain sentences, never the attribute" do
      areas = described_class.for_user(user)

      expect(areas).to be_present
      expect(areas.to_s).not_to include("data-byte")
      areas.each { |area|
        expect(area[:controls]).to be_present
        area[:controls].each { |control|
          expect(control[:label]).to be_present
          expect(control[:does]).to be_present
        }
      }
    end

    # The thing that started this: Eve asked how to stop being alerted, was
    # sent to her phone's settings, and the control was in the window she was
    # typing into. It has to be findable and it has to be distinguishable from
    # the speaker, which she would otherwise have been pointed at instead.
    it "carries the bell, and separates it from the sound toggle" do
      bell, speaker = %w[bell speaker].map { |word|
        described_class.for_user(user).flat_map { |a| a[:controls] }.find { |c| c[:label].include?(word) }
      }

      expect(bell[:does]).to include("notifications")
      expect(speaker[:does]).to include("does NOT stop notifications")
    end

    # Same rule AppPages follows: a surface somebody cannot use is furniture,
    # and describing it invites a question with no good answer.
    it "keeps the Claude-only strip away from the rest of the household" do
      housemate = described_class.for_user(user).pluck(:area)
      owner     = described_class.for_user(User.me).pluck(:area)

      expect(housemate).not_to include(:the_working_directory_strip)
      expect(owner).to include(:the_working_directory_strip)
    end
  end
end

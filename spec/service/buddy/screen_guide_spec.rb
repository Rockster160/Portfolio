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
    it "finds every claimed hook still in the markup", :aggregate_failures do
      described_class::SURFACES.each { |surface|
        surface[:controls].each { |control|
          expect(view).to include(control[:hook]), "#{surface[:name]}: #{control[:hook]}"
        }
      }
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
      guide = described_class.for_user(user)
      areas = guide[:areas]

      expect(areas).to be_present
      expect(guide.to_s).not_to include("data-byte")
      areas.each { |area|
        expect(area[:controls]).to be_present
        area[:controls].each { |control|
          expect(control[:label]).to be_present
          expect(control[:does]).to be_present
        }
      }
    end

    # The guide has to answer for things with no control too, or the nearest
    # row catches those questions. See ScreenGuide::NOT_ON_SCREEN.
    it "names the things that have no control" do
      absent = described_class.for_user(user)[:not_on_screen]

      expect(absent).to be_present
      expect(absent.pluck(:about).join(" ")).to include("stash", "app icon")
      absent.each { |row| expect(row[:says]).to be_present }
    end

    # Same rule AppPages follows: a surface somebody cannot use is furniture,
    # and describing it invites a question with no good answer.
    it "keeps the Claude-only strip away from the rest of the household" do
      housemate = described_class.for_user(user)[:areas].pluck(:area)
      owner     = described_class.for_user(User.me)[:areas].pluck(:area)

      expect(housemate).not_to include(:the_working_directory_strip)
      expect(owner).to include(:the_working_directory_strip)
    end
  end
end

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

    # The thing that started this: Eve asked how to stop being alerted, was
    # sent to her phone's settings, and the control was in the window she was
    # typing into. It has to be findable and it has to be distinguishable from
    # the sound row, which she would otherwise have been pointed at instead.
    #
    # Both moved into Settings on 2026-09-14, two taps deep rather than one, so
    # the guide matters MORE than it did when they were icons she could see.
    it "carries notifications, and separates them from the sound row" do
      notifications, sound = ["Notifications", "Sound"].map { |word|
        described_class.for_user(user)[:areas].flat_map { |a| a[:controls] }.find { |c| c[:label].include?(word) }
      }

      expect(notifications[:does]).to include("notifications")
      expect(sound[:does]).to include("does NOT stop notifications")
    end

    # Naming the panel and not the way in is a dead end: a row two taps deep
    # is only findable if the thing that opens it says what is behind it.
    it "says what Settings holds, from the drawer row that opens it" do
      drawer = described_class.for_user(user)[:areas].find { |a| a[:area] == :the_drawer }
      row    = drawer[:controls].find { |c| c[:label].include?("Settings") }

      expect(row[:does]).to include("Notifications")
      expect(row[:does]).to include("sound")
    end

    # Three questions in eight minutes, all answered with the Settings row,
    # because two of them had no control behind them and the guide said only
    # what EXISTS. See ScreenGuide::NOT_ON_SCREEN.
    it "names the things that have no control, so the loudest row stops catching them" do
      absent = described_class.for_user(user)[:not_on_screen]

      expect(absent).to be_present
      expect(absent.pluck(:about).join(" ")).to include("stash", "app icon")
      absent.each { |row| expect(row[:says]).to be_present }
    end

    # The pull itself: "THIS is the answer to stop alerting me" was the most
    # emphatic sentence in the file, and anything carrying the word
    # "notification" landed on it - including a question about the badge.
    it "scopes the emphatic notifications line to the question it answers" do
      controls = described_class.for_user(user)[:areas].flat_map { |a| a[:controls] }
      row      = controls.find { |c| c[:label].include?("Notifications") }

      expect(row[:does]).to include("turn notifications off")
      expect(row[:does]).to include("NOT the answer to a question about the number on the app icon")
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

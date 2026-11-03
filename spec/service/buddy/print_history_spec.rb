require "rails_helper"

# The printer's job log, rebuilt from the PrintStart / PrintFinish / PrintFailed
# events OctoPrint's webhooks leave behind — and the tool that hands the file
# names back so a print can be run again by name.
RSpec.describe Buddy::PrintHistory do
  let(:user)   { create(:user) }
  let(:seeds)  { [] }
  let!(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(Buddy::CompanionDelivery).to receive(:deliver_prompt) { |args| seeds << args[:seed] }
  end

  def started!(name, at: 2.hours.ago, estimate: 2400, filament: "Azure Blue")
    ActionEvent.create!(
      user: user, name: "PrintStart", notes: name, timestamp: at,
      data: { device: "zoro-pi-1", estimated_seconds: estimate, filament_name: filament }
    )
  end

  def finished!(start, at: 1.hour.ago, seconds: 2602)
    ActionEvent.create!(
      user: user, name: "PrintFinish", notes: start.notes, timestamp: at,
      data: { start_event_id: start.id, actual_seconds: seconds }
    )
  end

  def failed!(start, at: 1.hour.ago, seconds: 720, reason: "Print Failed", error: nil)
    ActionEvent.create!(
      user: user, name: "PrintFailed", notes: start.notes, timestamp: at,
      data: { start_event_id: start.id, elapsed_seconds: seconds, reason: reason, error: error }.compact
    )
  end

  describe ".call" do
    it "pairs a start with its finish, stamped by when it finished, with duration and filament", :aggregate_failures do
      zone  = ActiveSupport::TimeZone[user.timezone]
      start = started!("game_tray-vase", at: zone.parse("2026-08-05 05:59:00"), filament: "Azure Blue")
      finished!(start, at: zone.parse("2026-08-05 06:43:00"), seconds: 2602)

      line = travel_to(zone.parse("2026-08-05 12:00:00")) { described_class.call(user: user).first }

      expect(line).to start_with("game_tray-vase · finished ")
      expect(line).to include("Wed 8/5 6:43am", "after 43m", "Azure Blue")
    end

    # "How much longer" is the question about a running print, and one whose
    # finish webhook never landed must not read as running forever.
    it "reports a live print by how much is left, and stops calling it live once the estimate is long past", :aggregate_failures do
      started!("Wall_mount_phone_holder_v2", at: 20.minutes.ago, estimate: 14_640)
      started!("Mystery", at: 25.minutes.ago, estimate: 0)
      started!("Slime", at: 5.hours.ago, estimate: 2400)

      lines = freeze_time { described_class.call(user: user) }

      expect(lines.find { |l| l.start_with?("Wall_mount") }).to include("about 3h 44m left")
      expect(lines.find { |l| l.start_with?("Mystery") }).to include("still going ·")
      expect(lines.find { |l| l.start_with?("Slime") }).to include("never logged a finish")
    end

    # The topic doubles as the `reason`, so an ordinary failure would otherwise
    # render as "failed ... (Print Failed)".
    it "distinguishes a failure from a cancellation and surfaces the error, not the topic", :aggregate_failures do
      failed!(started!("Slime"), reason: "Print Failed", error: "Thermal runaway")
      failed!(started!("Benchy", at: 4.hours.ago), at: 3.hours.ago, reason: "Print Cancelled")
      failed!(started!("Vase", at: 6.hours.ago), at: 5.hours.ago, reason: "Print Failed")

      lines = described_class.call(user: user)
      expect(lines.find { |l| l.start_with?("Slime") }).to include("failed").and include("(Thermal runaway)")
      expect(lines.find { |l| l.start_with?("Benchy") }).to include("cancelled")
      expect(lines.find { |l| l.start_with?("Vase") }).not_to include("(Print Failed)")
    end

    it "collapses repeats of one file into one row, ordered by each file's latest run", :aggregate_failures do
      finished!(started!("Benchy", at: 30.hours.ago), at: 29.hours.ago)
      3.times { |i| finished!(started!("game_tray-vase", at: (i + 2).hours.ago), at: (i + 1).hours.ago) }

      lines = described_class.call(user: user)
      expect(lines.map { |l| l.split(" · ").first }).to eq(["game_tray-vase", "Benchy"])
      expect(lines.first).to include("3 runs")
      expect(lines.last).not_to include("runs")
    end

    it "bounds the window by days and ignores everything that isn't a print", :aggregate_failures do
      finished!(started!("Old thing", at: 90.days.ago), at: 89.days.ago)
      ActionEvent.create!(user: user, name: "Coffee", timestamp: 1.hour.ago)

      expect(described_class.call(user: user, days: 30)).to be_empty
    end

    # File names use separators where a person says spaces, so a literal
    # substring test would miss them. No name carries "thing", so a filler word
    # falls back to the words that do land.
    it "narrows to the words they said rather than typed", :aggregate_failures do
      finished!(started!("game_tray-vase"))
      finished!(started!("Wall_mount_phone_holder_v2", at: 4.hours.ago), at: 3.hours.ago)

      ["game tray", "game tray vase", "Game Tray", "game_tray-vase", "tray game"].each do |said|
        expect(described_class.call(user: user, query: said).first).to start_with("game_tray-vase"), said
      end
      ["phone", "phone holder", "that phone thing"].each do |said|
        lines = described_class.call(user: user, query: said)
        expect(lines.length).to eq(1), said
        expect(lines.first).to start_with("Wall_mount_phone_holder_v2"), said
      end
      expect(described_class.call(user: user, query: "benchy")).to be_empty
    end
  end

  describe ".reprint_function" do
    def function!(name)
      user.tasks.create!(
        name: name, listener: 'function("File" TAB String(""))::String',
        code: "a = String.new(\"ok\")::String", buddy_enabled: true
      )
    end

    it "finds the person's own reprint function, or nothing", :aggregate_failures do
      function!("Printer - Preheat")
      expect(described_class.reprint_function(user)).to be_nil

      again = function!("Print Again")
      expect(described_class.reprint_function(user)).to eq(again)
    end
  end

  describe "the print_history tool" do
    def read(payload={})
      Buddy::GPT::Turn.resolve_tool(
        Buddy::Tools[:print_history],
        { call_id: "call_1", name: :print_history, arguments: payload },
        user: user, conversation: convo,
      )
    end

    it "hands the file names back in the same turn the model asks for them", :aggregate_failures do
      finished!(started!("Wall_mount_phone_holder_v2"))

      result = read(query: "phone")
      expect(result[:status]).to eq(:answered)
      expect(result[:prints].first).to start_with("Wall_mount_phone_holder_v2")
      expect(Buddy::CompanionDelivery).not_to have_received(:deliver_prompt)
      expect(read(query: "nothing like this")[:prints]).to be_empty
    end

    # print_again refuses outright without a reprint function, so pointing at it
    # would spend a turn to arrive nowhere.
    it "points at print_again only when they have a reprint function", :aggregate_failures do
      finished!(started!("game_tray-vase"))
      expect(read[:how]).not_to include("print_again")

      user.tasks.create!(
        name: "Print Again", listener: 'function("File" TAB String(""))::String',
        code: "a = String.new(\"ok\")::String", buddy_enabled: true
      )
      expect(read[:how]).to include("print_again")
    end
  end
end

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
    it "pairs a start with its finish and reports how long it took" do
      finished!(started!("game_tray-vase"), seconds: 2602)

      line = described_class.call(user: user).first
      expect(line).to start_with("game_tray-vase · finished ")
      expect(line).to include("after 43m")
    end

    it "stamps a finished run by when it finished, not when it started" do
      zone  = ActiveSupport::TimeZone[user.timezone]
      start = started!("game_tray-vase", at: zone.parse("2026-08-05 05:59:00"))
      finished!(start, at: zone.parse("2026-08-05 06:43:00"))

      travel_to(zone.parse("2026-08-05 12:00:00")) {
        expect(described_class.call(user: user).first).to include("finished Wed 8/5 6:43am")
      }
    end

    # "How much longer" is the only question anyone asks about the print that's
    # still running, so don't hand back a raw total estimate to subtract from.
    it "reports a live print by how much of it is left" do
      started!("Wall_mount_phone_holder_v2", at: 20.minutes.ago, estimate: 14_640)

      freeze_time {
        expect(described_class.call(user: user).first).to include("still going - about 3h 44m left")
      }
    end

    it "says only that it's going when there's no estimate to go on" do
      started!("Mystery", at: 20.minutes.ago, estimate: 0)

      expect(described_class.call(user: user).first).to include("still going ·")
    end

    # A print whose finish webhook never landed would otherwise read as running
    # forever, which is a confident wrong answer to "did that one finish".
    it "stops calling a print live once its estimate is long past" do
      started!("Slime", at: 5.hours.ago, estimate: 2400)

      expect(described_class.call(user: user).first).to include("never logged a finish")
    end

    it "distinguishes a failure from a cancellation and surfaces the error" do
      failed!(started!("Slime"), reason: "Print Failed", error: "Thermal runaway")
      failed!(started!("Benchy", at: 4.hours.ago), at: 3.hours.ago, reason: "Print Cancelled")

      lines = described_class.call(user: user)
      expect(lines.find { |l| l.start_with?("Slime") }).to include("failed").and include("(Thermal runaway)")
      expect(lines.find { |l| l.start_with?("Benchy") }).to include("cancelled")
    end

    # The topic doubles as the `reason`, so an ordinary failure would otherwise
    # render as "failed ... (Print Failed)".
    it "leaves the bare webhook topic off the line" do
      failed!(started!("Slime"), reason: "Print Failed")

      expect(described_class.call(user: user).first).not_to include("(Print Failed)")
    end

    it "collapses repeats of one file into a single row carrying the latest run" do
      3.times { |i| finished!(started!("game_tray-vase", at: (i + 2).hours.ago), at: (i + 1).hours.ago) }
      finished!(started!("Benchy", at: 30.hours.ago), at: 29.hours.ago)

      lines = described_class.call(user: user)
      expect(lines.length).to eq(2)
      expect(lines.first).to start_with("game_tray-vase")
      expect(lines.first).to include("3 runs")
      expect(lines.last).not_to include("runs")
    end

    it "orders by the most recent run of each file" do
      finished!(started!("Benchy", at: 10.hours.ago), at: 9.hours.ago)
      finished!(started!("game_tray-vase", at: 3.hours.ago), at: 2.hours.ago)

      expect(described_class.call(user: user).map { |l| l.split(" · ").first }).to eq(
        ["game_tray-vase", "Benchy"],
      )
    end

    it "narrows to the words they used" do
      finished!(started!("Wall_mount_phone_holder_v2"))
      finished!(started!("game_tray-vase", at: 4.hours.ago), at: 3.hours.ago)

      lines = described_class.call(user: user, query: "phone")
      expect(lines.length).to eq(1)
      expect(lines.first).to start_with("Wall_mount_phone_holder_v2")
    end

    it "bounds the window by days" do
      finished!(started!("Old thing", at: 90.days.ago), at: 89.days.ago)

      expect(described_class.call(user: user, days: 30)).to be_empty
    end

    it "carries the filament through" do
      finished!(started!("game_tray-vase", filament: "Azure Blue"))

      expect(described_class.call(user: user).first).to include("Azure Blue")
    end

    it "ignores everything that isn't a print" do
      ActionEvent.create!(user: user, name: "Coffee", timestamp: 1.hour.ago)

      expect(described_class.call(user: user)).to be_empty
    end
  end

  describe ".reprint_function" do
    def function!(name)
      user.tasks.create!(
        name: name, listener: 'function("File" TAB String(""))::String',
        code: "a = String.new(\"ok\")::String", buddy_enabled: true
      )
    end

    it "finds the person's own reprint function" do
      function!("Printer - Preheat")
      again = function!("Print Again")

      expect(described_class.reprint_function(user)).to eq(again)
    end

    it "returns nothing when they don't have one" do
      function!("Printer - Preheat")

      expect(described_class.reprint_function(user)).to be_nil
    end
  end

  describe "the print_history tool" do
    let(:msg) { convo.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "ok") }

    def build(payload={})
      Buddy::ProposalBuilder.create(
        user: user, byte_message: msg,
        markers: [{ tool_name: :print_history, payload: payload, span: [0, 0] }]
      )
    end

    it "is registered as an auto read with no checklist row" do
      expect(Buddy::Tools[:print_history][:auto]).to be(true)
      expect(build[:action]).to be_nil
    end

    it "relays the file names for the next reply" do
      finished!(started!("Wall_mount_phone_holder_v2"))

      build(query: "phone")

      expect(seeds.last).to include("Wall_mount_phone_holder_v2")
    end

    it "points at the reprint function by its real name when they have one" do
      user.tasks.create!(
        name: "Print Again", listener: 'function("File" TAB String(""))::String',
        code: "a = String.new(\"ok\")::String", buddy_enabled: true
      )
      finished!(started!("game_tray-vase"))

      build

      expect(seeds.last).to include("call_jil_function").and include('name="Print Again"')
    end

    # call_jil_function raises on a name it can't match, so naming a function
    # they don't have would spend a turn to arrive nowhere.
    it "says nothing about reprinting when no such function exists" do
      finished!(started!("game_tray-vase"))

      build

      expect(seeds.last).not_to include("call_jil_function")
    end

    it "asks for another detail when nothing matches" do
      build(query: "nothing like this")

      expect(seeds.last).to include("no print on record")
    end
  end
end

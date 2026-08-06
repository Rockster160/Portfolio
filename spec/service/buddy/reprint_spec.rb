require "rails_helper"

# Starting a print goes to the PRINTER first, with whatever words the person
# used. The printer owns its filenames and may hold files that have never run,
# so our own history is the fallback, not the gate — and because the refusal has
# to reach the model in time for it to go looking, print_again reports back
# inside the turn rather than after the reply.
RSpec.describe Buddy::Reprint do
  let(:user)   { create(:user) }
  let!(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }

  # Whatever the printer says back, standing in for the HASS script behind the
  # Jil function.
  def printer_says(message)
    execution = instance_double(Jil::Executor, result: message)
    allow_any_instance_of(Task).to receive(:execute).and_return(execution)
    execution
  end

  def reprint_function!
    user.tasks.create!(
      name: "Print Again", listener: 'function("File" TAB String(""))::String',
      code: "a = String.new(\"ok\")::String", buddy_enabled: true
    )
  end

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    reprint_function!
  end

  describe ".call" do
    it "hands the printer the words it was given, untouched" do
      printer_says("Printing game_tray-vase.")

      expect_any_instance_of(Task).to receive(:execute).with(
        hash_including("file" => "game tray"), any_args
      ).and_return(instance_double(Jil::Executor, result: "Printing game_tray-vase."))

      described_class.call(user: user, file: "game tray")
    end

    it "sends no file at all when they meant the last print" do
      expect_any_instance_of(Task).to receive(:execute).with({}, any_args)
        .and_return(instance_double(Jil::Executor, result: "Printing game_tray-vase."))

      expect(described_class.call(user: user, file: nil)[:file]).to be_nil
    end

    # Verbatim from the HASS script, both branches.
    it "reads a start off the success message" do
      printer_says("Printing game_tray-vase.")

      result = described_class.call(user: user, file: "game_tray-vase")
      expect(result[:outcome]).to eq(:started)
    end

    it "reads a refusal off the real one" do
      printer_says("Printer is preheating, but nothing will print - no matching file.")

      expect(described_class.call(user: user, file: "game tray")[:outcome]).to eq(:missed)
    end

    # The printer does its own matching, so the name it reports back is the real
    # one — the only place it appears without a second lookup.
    it "picks the filename the printer matched out of the message" do
      printer_says("Printing game_tray-vase.")

      expect(described_class.call(user: user, file: "game tray")[:printed]).to eq("game_tray-vase")
    end

    # Reasonable neighbours of the real refusal, in case the script is reworded.
    [
      "No such file: game tray",
      "File not found on the printer",
      "Couldn't find a file named game tray",
      "cannot match game tray",
    ].each do |refusal|
      it "also reads a refusal off #{refusal.inspect}" do
        printer_says(refusal)

        expect(described_class.call(user: user, file: "game tray")[:outcome]).to eq(:missed)
      end
    end

    # The polarity is the whole safety property. Anything that isn't recognisably
    # a start is UNCLEAR, never a start: a refusal read as a print is announced
    # as one, while an unclear answer just gets quoted back.
    it "refuses to call an answer it can't read a start" do
      printer_says("the spool is empty")

      result = described_class.call(user: user, file: "game_tray-vase")
      expect(result[:outcome]).to eq(:unclear)
      expect(result[:printed]).to be_nil
      expect(result[:printer_said]).to eq("the spool is empty")
    end

    it "treats the task's own no-status fallback as unclear" do
      printer_says("The printer turned on and is preheating, but I didn't get a print status back.")

      expect(described_class.call(user: user, file: "x")[:outcome]).to eq(:unclear)
    end

    it "says it can't tell when the printer answers with nothing" do
      printer_says("")

      expect(described_class.call(user: user, file: "x")[:outcome]).to eq(:unclear)
    end

    it "refuses when they have no reprint function at all" do
      user.tasks.destroy_all

      expect { described_class.call(user: user, file: "x") }.to raise_error(/no reprint function/)
    end
  end

  describe "the print_again tool" do
    def send!(payload={})
      Buddy::GPT::Turn.resolve_tool(
        Buddy::Tools[:print_again],
        { call_id: "call_1", name: :print_again, arguments: payload },
        user: user, conversation: convo,
      )
    end

    def chips
      convo.byte_messages.where("metadata->>'kind' = 'buddy_activity'").order(:id)
    end

    it "settles in the turn so the model sees the printer's answer" do
      printer_says("Printing game_tray-vase.")

      expect(Buddy::Tools.answers?(Buddy::Tools[:print_again])).to be(true)
      expect(send!(file: "game_tray-vase")[:status]).to eq(:answered)
    end

    # The point of the whole flow: a refusal has to arrive as a refusal, with
    # the next move spelled out, or the model apologises and stops.
    it "tells the model to go find the real name when the printer says no" do
      printer_says("Printer is preheating, but nothing will print - no matching file.")

      result = send!(file: "game tray")
      expect(result[:outcome]).to eq(:missed)
      expect(result[:printer_said]).to include("no matching file")
      expect(result[:how]).to include("print_history").and include("NOTHING is printing")
    end

    it "leaves a chip for a start" do
      printer_says("Printing game_tray-vase.")

      send!(file: "game_tray-vase")

      expect(chips.last.body).to include("game_tray-vase")
      expect(chips.last.metadata["ok"]).to be(true)
    end

    # Asked for "game tray", the printer matched `game_tray-vase` and said so.
    # That name is what belongs on the receipt and in the reply.
    it "reports the name the printer matched, not the words they used" do
      printer_says("Printing game_tray-vase.")

      result = send!(file: "game tray")

      expect(result[:printing]).to eq("game_tray-vase")
      expect(chips.last.body).to include("game_tray-vase")
      expect(chips.last.metadata.dig("payload", "file")).to eq("game_tray-vase")
    end

    # Two chips across a retry is the honest record: the printer was asked
    # twice and answered differently.
    it "leaves a chip for a refusal too, marked as one" do
      printer_says("No such file: game tray")

      send!(file: "game tray")

      expect(chips.last.body).to include("didn't know")
      expect(chips.last.metadata["ok"]).to be(false)
    end

    it "refuses up front when there's no reprint function to call" do
      user.tasks.destroy_all

      expect(send![:status]).to eq("failed")
      expect(chips).to be_empty
    end

    # Level-1 tools normally execute in ProposalBuilder after the reply. This
    # one already ran, and running it again would start a second print.
    it "never reaches ProposalBuilder" do
      printer_says("Printing game_tray-vase.")

      result = Buddy::ProposalBuilder.create(
        user: user, byte_message: convo.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "ok"),
        markers: [{ tool_name: :print_again, payload: { file: "game_tray-vase" } }]
      )

      expect(result[:auto_ran]).to be(false)
      expect(chips).to be_empty
    end
  end
end

require "rails_helper"

# Every command sent to the car has to say so. The car acts silently, so without
# the line there's no audit trail of what Jarvis/the dashboard/automation just
# did — and the one time it mattered, a successful pre-conditioning start went
# unreported and got pressed a second time by hand.
#
# It's a `say` and not a `ping`: a push is an interruption, and a car command is
# either something the person just asked for or automation doing its job.
# Jil::Methods::Tesla#announce already worked this way; this is the other entry
# point (dashboard cell + `car ...` voice commands) catching up.
RSpec.describe TeslaCommand do
  # `Tesla` forwards everything to a TeslaControl via method_missing, so the
  # double has to stand in for the controller — a verified double of Tesla
  # itself implements none of these.
  let(:controller) { instance_double(TeslaControl) }
  let(:says) { [] }

  before do
    allow(TeslaControl).to receive(:me).and_return(controller)
    allow(controller).to receive_messages(
      vin: "5YJ3E1EA9NF355991", start_car: true, off_car: true,
      honk: true, doors: true, set_temp: true
    )
    allow(described_class).to receive(:broadcast)
    allow(::Jarvis).to receive(:say) { |msg, *| says << msg }
    allow(::Jarvis).to receive(:ping)
  end

  it "says what it did instead of pushing it" do
    described_class.command(:start)

    expect(says).to eq(["Starting car"])
    expect(::Jarvis).not_to have_received(:ping)
  end

  it "says it for every command, not just the ones that reach the car" do
    described_class.command(:off)
    described_class.command(:honk)
    described_class.command(:lock)
    described_class.command(:temp, "74")

    expect(says).to eq([
      "Stopping car",
      "Honking the horn",
      "Locking car doors",
      "Car temp set to 74",
    ])
  end

  it "says the fallback when it can't parse the command" do
    described_class.command(:pirouette)

    expect(says).to eq(["Not sure how to tell car: pirouette"])
  end

  # The quick path only parses and hands off to TeslaCommandWorker, which
  # re-dispatches for real. Announcing in both places would say it twice.
  it "stays quiet on the quick pass and lets the worker do the talking" do
    allow(TeslaCommandWorker).to receive(:perform_async)

    described_class.quick_command(:start)

    expect(says).to be_empty
    expect(TeslaCommandWorker).to have_received(:perform_async).with("start", "")
  end
end

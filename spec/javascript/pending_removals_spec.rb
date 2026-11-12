require "rails_helper"

# A list item removed from the Dashboard stays pending until a list update
# arrives without it, and its removal keeps going out until then.
RSpec.describe "Dashboard pending list removals" do
  let(:result) { JsRunner.output("spec/javascript/pending_removals_runner.js") }

  it "sends a removal straight away while connected" do
    expect(result["connected"]).to eq({ "sent" => ["Milk"], "pending" => true })
  end

  it "holds removals while disconnected and sends them all once open" do
    expect(result["queued"]["sentWhileClosed"]).to eq([])
    expect(result["queued"]["sentOnOpen"]).to eq(["Milk", "Eggs"])
  end

  it "resends a removal when an update still holds the item" do
    expect(result["still_there"]).to eq({ "sent" => ["Milk", "Milk"], "pending" => true })
  end

  it "leaves an item alone once it has gone and been put back" do
    expect(result["put_back"]).to eq(
      { "goneAfterUpdate" => true, "pending" => false, "sent" => ["Milk"] },
    )
  end

  it "cancels a removal that is toggled again before it goes out" do
    expect(result["undo"]).to eq({ "undone" => false, "pending" => false, "sent" => [] })
  end

  it "retries only after the interval has passed" do
    expect(result["retry"]).to eq({ "early" => false, "late" => true, "sent" => ["Milk", "Milk"] })
  end

  it "has nothing to retry when nothing is pending" do
    expect(result["retry_idle"]).to eq({ "idle" => false, "sent" => [] })
  end
end

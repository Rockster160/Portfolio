require "rails_helper"

# remind_when is an AUTO tool (like schedule_reminder): it runs on the spot,
# creates a BuddyWatch, and drops an activity-receipt chip - no checklist.
RSpec.describe "remind_when tool" do
  let(:user)   { create(:user) }
  let!(:convo) { ByteConversation.create!(user: user, mode: :buddy, name: "Buddy", last_message_at: Time.current) }
  let(:msg)    { convo.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "ok") }

  before { allow(MonitorChannel).to receive(:broadcast_to) }

  def run(payload)
    markers = [{ tool_name: :remind_when, payload: payload, span: [0, 0] }]
    Buddy::ProposalBuilder.create(user: user, byte_message: msg, markers: markers)
  end

  it "creates a chore-condition watch as an auto tool (no checklist)" do
    result = nil
    expect { result = run(text: "floss", trigger: "chore", target: "Brush Teeth") }
      .to change { BuddyWatch.count }.by(1)

    expect(result[:action]).to be_nil
    expect(result[:auto_ran]).to be(true)

    w = BuddyWatch.last
    expect(w.trigger_scope).to eq("chore_completion")
    expect(w.match).to eq("action" => "completed", "chore_name" => "Brush Teeth")
    expect(w.kind).to eq("prompt")
    expect(w.one_shot).to be(true)

    chip = convo.byte_messages.where("metadata->>'kind' = 'buddy_activity'").last
    expect(chip.body).to match(/will remind you next time you finish Brush Teeth/)
  end

  it "refuses to set a location watch for a place it can't resolve, and asks instead" do
    # Not a contact, not on the calendar, and geocoding finds nothing → we
    # genuinely don't know where this is, so no name-only watch is created.
    allow_any_instance_of(AddressBook).to receive(:geocode).and_return(nil)

    expect { run(text: "grab my RX", trigger: "arrive", target: "the blorp") }
      .not_to change { BuddyWatch.count }

    chip = convo.byte_messages.where("metadata->>'kind' = 'buddy_activity'").last
    expect(chip.body).to match(/Not sure where the blorp is/)
  end

  it "resolves a general place by geocoding it (known → watch with coords)" do
    allow_any_instance_of(AddressBook).to receive(:geocode).and_return([40.45, -111.77])

    expect { run(text: "grab my RX", trigger: "arrive", target: "the Plunge in Alpine") }
      .to change { BuddyWatch.count }.by(1)
    w = BuddyWatch.last
    expect(w.match["action"]).to eq("arrived")
    expect(w.match["place"]).to eq("name" => "the Plunge in Alpine", "loc" => [40.45, -111.77])
  end

  it "captures a known place's coordinates so matching survives a rename" do
    contact = user.contacts.create!(name: "Serenity")
    contact.addresses.create!(user: user, street: "123 Calm Way", lat: 40.5, lng: -111.9, primary: true)

    run(text: "grab my RX", trigger: "arrive", target: "serenity")
    w = BuddyWatch.last
    expect(w.match["place"]["name"]).to eq("Serenity")
    expect(w.match["place"]["address"]).to eq("123 Calm Way")
    expect(w.match["place"]["loc"]).to eq([40.5, -111.9])
  end

  it "cross-matches a place name via the agenda (TMS -> Serenity's coords)" do
    # "TMS" is not a contact - it's how the appointment shows on the calendar,
    # and that calendar event carries the real address (contact Serenity's).
    # Stub geocode: AgendaItem.create! fires the agenda-travel chain (which
    # geocodes), and it's the resolver's last-resort fallback too.
    allow_any_instance_of(AddressBook).to receive(:geocode).and_return([40.43, -111.88])
    contact = user.contacts.create!(name: "Serenity")
    contact.addresses.create!(user: user, street: "3300 N Triumph Blvd", lat: 40.43, lng: -111.88, primary: true)
    agenda = Agenda.create!(user: user, name: "Cal")
    AgendaItem.create!(
      agenda: agenda, name: "TMS", kind: :event, location: "3300 N Triumph Blvd",
      start_at: 1.hour.from_now, end_at: 2.hours.from_now,
    )

    run(text: "grab your Loops", trigger: "arrive", target: "TMS")
    w = BuddyWatch.last
    expect(w.match["place"]["name"]).to eq("TMS")
    expect(w.match["place"]["address"]).to eq("3300 N Triumph Blvd")
    expect(w.match["place"]["loc"]).to eq([40.43, -111.88])
  end

  it "builds a deploy watch with an empty match" do
    run(text: "the deploy's done", trigger: "deploy")
    w = BuddyWatch.last
    expect(w.trigger_scope).to eq("deploy")
    expect(w.match).to eq({})
  end

  it "makes a repeating watch when repeat=true" do
    run(text: "floss", trigger: "chore", target: "Brush Teeth", repeat: true)
    expect(BuddyWatch.last.one_shot).to be(false)
  end

  it "surfaces active watches in Buddy::Context" do
    run(text: "floss", trigger: "chore", target: "Brush Teeth")
    ctx = Buddy::Context.build(user, convo)
    expect(ctx[:active_watches].map { |w| w[:body] }).to include("floss")
    expect(ctx[:active_watches].first[:when]).to include("Brush Teeth")
  end
end

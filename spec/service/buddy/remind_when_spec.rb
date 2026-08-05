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
      .to change(BuddyWatch, :count).by(1)

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

  # Prod watch 13: "Let me know each time the doorbell sees somebody today"
  # became a standing watch. Nothing would ever have retired it - it would keep
  # pinging about a day that was over until somebody noticed and deleted it.
  describe "a watch bounded in time" do
    let(:zone) { ActiveSupport::TimeZone[user.timezone] }

    def watch_until(phrase)
      run(
        text: "something landed", trigger: "custom", repeat: true,
        listener: "item:action:added", when_phrase: "when something is added",
        expires: phrase
      )
      BuddyWatch.last
    end

    def expiry_for(phrase)
      watch_until(phrase).expires_at
    end

    it "stops at the end of today, not the moment it was set" do
      ends = expiry_for("today").in_time_zone(zone)

      expect(ends.to_date).to eq(Time.current.in_time_zone(zone).to_date)
      expect(ends.hour).to eq(23)
    end

    it "reads tomorrow, a span of days, and a plain date" do
      today = Time.current.in_time_zone(zone).to_date

      expect(expiry_for("tomorrow").in_time_zone(zone).to_date).to eq(today + 1)
      expect(expiry_for("3 days").in_time_zone(zone).to_date).to eq(today + 3)
      expect(expiry_for("2 weeks").in_time_zone(zone).to_date).to eq(today + 14)
      expect(expiry_for((today + 5).iso8601).in_time_zone(zone).to_date).to eq(today + 5)
    end

    it "leaves a standing watch open-ended" do
      run(text: "a deploy finished", trigger: "deploy", repeat: true)

      expect(BuddyWatch.last.expires_at).to be_nil
    end

    it "says when it stops, rather than implying it runs forever" do
      watch_until("today")

      chip = convo.byte_messages.where("metadata->>'kind' = 'buddy_activity'").last
      expect(chip.body).to match(/until/i)
    end

    # Ignoring it would arm forever the one thing they asked to stop.
    it "refuses a phrase it can't read rather than dropping it" do
      tool = Buddy::Tools[:remind_when]
      payload = { text: "x", trigger: "deploy", expires: "whenever-ish" }
      normalized, = Buddy::Tools.validate_payload(tool, payload)

      expect { tool[:confirm].call(normalized, Buddy::ToolContext.new(user, conversation: convo)) }
        .to raise_error(/couldn't read/i)
    end
  end

  # Prod: "I need to check the front flower bed daily" became a custom watch on
  # `item:list:name:/^Daily front flower bed check$/`. Well-formed, real scope,
  # and no such list has ever existed - so it could never fire, and it sat there
  # looking set. A watch that fails by being silent is the worst shape there is.
  describe "a listener pointed at something that isn't there" do
    let(:tool) { Buddy::Tools[:remind_when] }
    let(:ctx)  { Buddy::ToolContext.new(user, conversation: convo) }

    def confirm(listener)
      tool[:confirm].call(
        { text: "check it", trigger: :custom, listener: listener, when_phrase: "when it lands" }, ctx
      )
    end

    def list!(name)
      List.create!(name: name).tap { |list| UserList.create!(user: user, list: list, is_owner: true) }
    end

    it "refuses a list nobody has" do
      expect { confirm("item:action:added item:list:name:/^Daily front flower bed check$/") }
        .to raise_error(/no list called "Daily front flower bed check"/i)
    end

    # And says what they should have reached for instead.
    it "points at the calendar when the ask was really a clock" do
      expect { confirm("item:action:added item:list:name:/^Nope$/") }
        .to raise_error(/recurring agenda task/i)
    end

    it "allows one that does exist" do
      list!("Claude")

      expect { confirm("item:action:added item:list:name:/^Claude$/") }.not_to raise_error
    end

    it "matches the name case-insensitively rather than being fussy" do
      list!("Claude")

      expect { confirm("item:action:added item:list:name:/^claude$/") }.not_to raise_error
    end

    it "refuses a section nobody has" do
      list!("Claude")

      expect { confirm("item:action:added item:section:name:/^Nowhere$/") }
        .to raise_error(/no section called "Nowhere"/i)
    end

    it "allows a section that exists" do
      Section.create!(list: list!("Claude"), name: "Ocs-Backend", color: "#888888")

      expect { confirm("item:action:added item:section:name:/^Ocs-Backend$/") }.not_to raise_error
    end

    # A loose pattern is a pattern, not a name - several things could satisfy
    # it, so refusing because no list is spelled like the regex would be wrong.
    it "leaves an unanchored pattern alone" do
      expect { confirm("item:action:added item:list:name:/claude/i") }.not_to raise_error
    end

    it "leaves a listener that names no list alone" do
      expect { confirm("item:action:added") }.not_to raise_error
    end
  end

  it "refuses to set a location watch for a place it can't resolve, and asks instead" do
    # Not a contact, not on the calendar, and geocoding finds nothing → we
    # genuinely don't know where this is, so no name-only watch is created.
    allow_any_instance_of(AddressBook).to receive(:geocode).and_return(nil)

    expect { run(text: "grab my RX", trigger: "arrive", target: "the blorp") }
      .not_to(change(BuddyWatch, :count))

    chip = convo.byte_messages.where("metadata->>'kind' = 'buddy_activity'").last
    expect(chip.body).to match(/Not sure where the blorp is/)
  end

  it "resolves a general place by geocoding it (known → watch with coords)" do
    allow_any_instance_of(AddressBook).to receive(:geocode).and_return([40.45, -111.77])

    expect { run(text: "grab my RX", trigger: "arrive", target: "the Plunge in Alpine") }
      .to change(BuddyWatch, :count).by(1)
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
      start_at: 1.hour.from_now, end_at: 2.hours.from_now
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

  # Prod: a deploy watch set on the 28th sat unfired for two days, and a second
  # one set on the 30th looked like the only one there was. When deploys started
  # matching again, one deploy pinged twice. Every deploy watch carries an empty
  # match, so there is nothing in the request itself to tell them apart - the
  # only place this can surface is at confirm time, before Buddy speaks.
  describe "a watch that's already listening for the same thing" do
    def confirm(payload)
      tool = Buddy::Tools[:remind_when]
      normalized, = Buddy::Tools.validate_payload(tool, payload)
      tool[:confirm].call(normalized, Buddy::ToolContext.new(user, conversation: convo))
    end

    it "warns rather than refusing, and names the one already set" do
      run(text: "let you know the deploy finished", trigger: "deploy")

      summary = confirm(text: "ping me on every deploy", trigger: "deploy", repeat: true)[:summary]

      expect(summary).to include("ALREADY listening")
      expect(summary).to include("let you know the deploy finished")
      expect(summary).to include("cancel_reminder")
    end

    it "says nothing when the only match is a watch that's already been used up" do
      run(text: "let you know the deploy finished", trigger: "deploy")
      BuddyWatch.last.update!(fired_at: Time.current)

      expect(confirm(text: "ping me on every deploy", trigger: "deploy")[:summary]).not_to include("ALREADY")
    end

    it "leaves a genuinely different condition alone" do
      run(text: "floss", trigger: "chore", target: "Brush Teeth")

      expect(confirm(text: "stretch", trigger: "chore", target: "Shower")[:summary]).not_to include("ALREADY")
    end

    # Two nudges for one condition are ordinary. The warning is information, not
    # an objection, and it must never stop the second one being set.
    it "flags a non-empty match too, and still sets the second watch" do
      run(text: "shower", trigger: "chore", target: "Brush Teeth")

      expect(confirm(text: "do laundry", trigger: "chore", target: "Brush Teeth")[:summary]).to include("shower")
      expect { run(text: "do laundry", trigger: "chore", target: "Brush Teeth") }
        .to change(BuddyWatch, :count).by(1)
    end
  end

  it "surfaces active watches in Buddy::Context" do
    run(text: "floss", trigger: "chore", target: "Brush Teeth")
    ctx = Buddy::Context.build(user, convo)
    expect(ctx[:active_watches].pluck(:body)).to include("floss")
    expect(ctx[:active_watches].first[:when]).to include("Brush Teeth")
  end
end

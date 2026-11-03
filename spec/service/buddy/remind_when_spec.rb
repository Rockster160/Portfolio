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

  def chip
    convo.byte_messages.where("metadata->>'kind' = 'buddy_activity'").last
  end

  def confirm(payload, context=nil)
    tool = Buddy::Tools[:remind_when]
    normalized, = Buddy::Tools.validate_payload(tool, payload)
    tool[:confirm].call(normalized, context || Buddy::ToolContext.new(user, conversation: convo))
  end

  describe "chore watches" do
    it "creates a one-shot chore-condition watch as an auto tool, with no checklist", :aggregate_failures do
      result = nil
      expect { result = run(text: "floss", trigger: "chore", target: "Brush Teeth") }.to change(BuddyWatch, :count).by(1)

      expect(result[:action]).to be_nil
      expect(result[:auto_ran]).to be(true)
      expect(chip).to be_present

      w = BuddyWatch.last
      expect(w.trigger_scope).to eq("chore_completion")
      expect(w.listener).to eq("chore_completion:action::completed chore_name::\"Brush Teeth\"")
      expect(w.kind).to eq("prompt")
      expect(w.one_shot).to be(true)

      run(text: "floss", trigger: "chore", target: "Brush Teeth", repeat: true)
      expect(BuddyWatch.last.one_shot).to be(false)
    end

    # `except` is the trigger's own narrowing term, negated, so it works for
    # any trigger that narrows by name - not only places.
    it "excludes a chore the same way it excludes a place", :aggregate_failures do
      run(text: "nice work", trigger: "chore", except: "Dishes")
      w = BuddyWatch.last

      expect(w.listener).to eq("chore_completion:action::completed -chore_name::Dishes")
      expect(w.matches?(action: "completed", chore_name: "Laundry")).to be(true)
      expect(w.matches?(action: "completed", chore_name: "dishes")).to be(false)
    end
  end

  it "builds a deploy watch with an empty match, open-ended", :aggregate_failures do
    run(text: "the deploy's done", trigger: "deploy", repeat: true)
    w = BuddyWatch.last

    expect(w.trigger_scope).to eq("deploy")
    expect(w.listener).to eq("deploy")
    expect(w.expires_at).to be_nil
  end

  it "surfaces active watches in Buddy::Context", :aggregate_failures do
    run(text: "floss", trigger: "chore", target: "Brush Teeth")
    ctx = Buddy::Context.build(user, convo)

    expect(ctx[:active_watches].pluck(:body)).to include("floss")
    expect(ctx[:active_watches].first[:when]).to include("Brush Teeth")
  end

  # arrive/depart need a place; "any time my phone or the car arrives or
  # leaves" is the travel trigger.
  describe "every arrival and departure, anywhere" do
    it "is one repeating watch for the phone and the car, narrowable to one of them", :aggregate_failures do
      text = "{{ source }}: {{ action }} {{ location }}"
      run(text: text, trigger: "travel", repeat: true)

      watch = BuddyWatch.last
      expect([watch.trigger_scope, watch.listener, watch.body, watch.one_shot]).to eq(["travel", "travel source::OR(phone tesla)", text, false])
      expect(confirm(text: "x", trigger: "travel", target: "the car")[:resolved][:listener]).to eq("travel source::tesla")
      expect(confirm(text: "x", trigger: "travel", target: "phone")[:resolved][:listener]).to eq("travel source::phone")
    end

    it "refuses a placeless depart, or a place on the travel trigger", :aggregate_failures do
      expect { confirm(text: "x", trigger: "depart", repeat: true) }.to raise_error(/travel/)
      expect { confirm(text: "x", trigger: "travel", target: "Costco") }.to raise_error(RuntimeError)
    end

    it "posts as a banner when asked, but only in their own thread", :aggregate_failures do
      run(text: "{{ source }}: {{ action }}", trigger: "travel", repeat: true, banner: true)
      expect(BuddyWatch.last).to be_banner

      ctx = Buddy::ToolContext.new(user, conversation: convo)
      allow(ctx).to receive(:resolve_household_user).and_return(create(:user))
      expect { confirm({ text: "x", trigger: "travel", banner: true, notify: "Chelsea" }, ctx) }.to raise_error(RuntimeError)
    end
  end

  # A watch about "today" that nothing retires keeps pinging about a day that
  # is over.
  describe "a watch bounded in time" do
    let(:zone) { ActiveSupport::TimeZone[user.timezone] }

    def expiry_for(phrase)
      run(
        text: "something landed", trigger: "custom", repeat: true,
        listener: "item:action:added", when_phrase: "when something is added",
        expires: phrase
      )
      BuddyWatch.last.expires_at.in_time_zone(zone)
    end

    it "stops at the end of today, tomorrow, a span of days, or a plain date", :aggregate_failures do
      today = Time.current.in_time_zone(zone).to_date

      ends = expiry_for("today")
      expect(ends.to_date).to eq(today)
      expect(ends.hour).to eq(23)
      expect(expiry_for("tomorrow").to_date).to eq(today + 1)
      expect(expiry_for("3 days").to_date).to eq(today + 3)
      expect(expiry_for("2 weeks").to_date).to eq(today + 14)
      expect(expiry_for((today + 5).iso8601).to_date).to eq(today + 5)
    end

    # Ignoring it would arm forever the one thing they asked to stop.
    it "refuses a phrase it can't read rather than dropping it" do
      expect { confirm(text: "x", trigger: "deploy", expires: "whenever-ish") }.to raise_error(RuntimeError)
    end
  end

  # A well-formed listener on a list or section that doesn't exist could never
  # fire, and would sit there looking set.
  describe "a listener pointed at something that isn't there" do
    def custom(listener)
      confirm(text: "check it", trigger: :custom, listener: listener, when_phrase: "when it lands")
    end

    def list!(name)
      List.create!(name: name).tap { |list| UserList.create!(user: user, list: list, is_owner: true) }
    end

    it "refuses a list or section nobody has", :aggregate_failures do
      list!("Claude")

      expect { custom("item:action:added item:list:name:/^Daily front flower bed check$/") }.to raise_error(/Daily front flower bed check/)
      expect { custom("item:action:added item:section:name:/^Nowhere$/") }.to raise_error(/Nowhere/)
    end

    # A loose pattern is a pattern, not a name - several things could satisfy it.
    it "allows a list or section that exists, any case, an unanchored pattern, or no list at all", :aggregate_failures do
      Section.create!(list: list!("Claude"), name: "Ocs-Backend", color: "#888888")

      [
        "item:action:added item:list:name:/^Claude$/",
        "item:action:added item:list:name:/^claude$/",
        "item:action:added item:section:name:/^Ocs-Backend$/",
        "item:action:added item:list:name:/claude/i",
        "item:action:added",
      ].each do |listener|
        expect { custom(listener) }.not_to raise_error, listener
      end
    end
  end

  describe "a place" do
    it "refuses a place it can't resolve, and asks instead of setting a name-only watch" do
      allow_any_instance_of(AddressBook).to receive(:geocode).and_return(nil)

      expect { run(text: "grab my RX", trigger: "arrive", target: "the blorp") }.not_to(change(BuddyWatch, :count))
      expect(chip.body).to include("the blorp")
    end

    it "resolves a general place by geocoding it" do
      allow_any_instance_of(AddressBook).to receive(:geocode).and_return([40.45, -111.77])

      expect { run(text: "grab my RX", trigger: "arrive", target: "the Plunge in Alpine") }.to change(BuddyWatch, :count).by(1)
      expect(BuddyWatch.last.listener).to eq("travel:action::arrived near(40.45 -111.77 165m)")
    end

    # A same-named place geocoded across the country can never be arrived at;
    # the cap is AgendaTravelChain::Resolver::MAX_DRIVE_MILES.
    it "refuses coordinates beyond driving distance, and takes them within it", :aggregate_failures do
      allow_any_instance_of(AddressBook).to receive(:current_loc).and_return([40.48, -111.99])
      allow_any_instance_of(AddressBook).to receive(:geocode).and_return([39.9823212, -76.3560719])

      expect { run(text: "I like the strawberry lemonade", trigger: "arrive", target: "Slackwater") }.not_to(change(BuddyWatch, :count))
      expect(chip.body).to include("Slackwater")

      allow_any_instance_of(AddressBook).to receive(:geocode).and_return([40.76, -111.89])
      expect { run(text: "I like the strawberry lemonade", trigger: "arrive", target: "Slackwater") }.to change(BuddyWatch, :count).by(1)
      expect(BuddyWatch.last.listener).to eq("travel:action::arrived near(40.76 -111.89 165m)")
    end

    it "captures a known place's coordinates so matching survives a rename" do
      contact = user.contacts.create!(name: "Serenity")
      contact.addresses.create!(user: user, street: "123 Calm Way", lat: 40.5, lng: -111.9, primary: true)

      run(text: "grab my RX", trigger: "arrive", target: "serenity")

      expect(BuddyWatch.last.listener).to eq("travel:action::arrived near(40.5 -111.9 165m)")
    end

    # "TMS" is not a contact - it's how the appointment shows on the calendar,
    # and that event carries the real address. AgendaItem.create! fires the
    # agenda-travel chain, which geocodes, hence the stub.
    it "cross-matches a place name via the agenda" do
      allow_any_instance_of(AddressBook).to receive(:geocode).and_return([40.43, -111.88])
      contact = user.contacts.create!(name: "Serenity")
      contact.addresses.create!(user: user, street: "3300 N Triumph Blvd", lat: 40.43, lng: -111.88, primary: true)
      agenda = Agenda.create!(user: user, name: "Cal")
      AgendaItem.create!(
        agenda: agenda, name: "TMS", kind: :event, location: "3300 N Triumph Blvd",
        start_at: 1.hour.from_now, end_at: 2.hours.from_now
      )

      run(text: "grab your Loops", trigger: "arrive", target: "TMS")

      expect(BuddyWatch.last.listener).to eq("travel:action::arrived near(40.43 -111.88 165m)")
    end

    it "watches for leaving anywhere but home, even reported from up the street", :aggregate_failures do
      home = user.contacts.create!(name: "Home")
      home.addresses.create!(user: user, street: "1 Home St", lat: 40.4805, lng: -111.9982, primary: true)
      run(text: "Tell Chelsea I'm on the way home.", trigger: "depart", except: "home")
      watch = BuddyWatch.last

      expect(watch.trigger_scope).to eq("travel")
      expect(watch.listener).to eq("travel:action::departed -near(40.4805 -111.9982 550m)")
      expect(watch.matches?(action: "departed", lat: 40.48449, lng: -111.98563, location: "Herriman")).to be(true)
      expect(watch.matches?(action: "departed", lat: 40.4805, lng: -111.9982, location: "Home")).to be(false)
      expect(watch.matches?(action: "departed", lat: 40.4815, lng: -111.9960, location: "Herriman")).to be(false)
      expect(watch.matches?(action: "arrived", lat: 40.48449, lng: -111.98563)).to be(false)
    end
  end

  # Every deploy watch carries an empty match, so nothing in a request tells
  # two apart; the only place a duplicate can surface is at confirm time. Two
  # nudges for one condition are ordinary, so it warns and never refuses.
  describe "a watch that's already listening for the same thing" do
    it "names the live one already set, but not a used-up one", :aggregate_failures do
      run(text: "let you know the deploy finished", trigger: "deploy")
      expect(confirm(text: "ping me on every deploy", trigger: "deploy", repeat: true)[:summary]).to include("let you know the deploy finished")

      BuddyWatch.last.update!(fired_at: Time.current)
      expect(confirm(text: "ping me on every deploy", trigger: "deploy")[:summary]).not_to include("ALREADY")
    end

    it "flags a matching chore watch but not a different one, and still sets the second", :aggregate_failures do
      run(text: "shower", trigger: "chore", target: "Brush Teeth")

      # A different condition can still be mentioned as just set, but not as a duplicate.
      expect(confirm(text: "stretch", trigger: "chore", target: "Shower")[:summary]).not_to include("ALREADY")
      expect(confirm(text: "do laundry", trigger: "chore", target: "Brush Teeth")[:summary]).to include("shower")
      expect { run(text: "do laundry", trigger: "chore", target: "Brush Teeth") }.to change(BuddyWatch, :count).by(1)
    end
  end
end

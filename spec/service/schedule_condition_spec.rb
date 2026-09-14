require "rails_helper"

# Prod 42/43/44: three reminders an hour apart reading "Charge village car if
# the chore isn't done yet." A BuddyReminder of kind `reminder` renders its body
# and posts it, so the "if" was a sentence the person read rather than anything
# the app evaluated — all three would arrive whether or not the car got charged,
# and the second and third would arrive after they had.
#
# A condition is a SEARCH, in the syntax the whole app already searches with.
RSpec.describe ScheduleCondition do
  let(:user)       { create(:user) }
  let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: user) }
  let!(:chore)     { create(:chore, created_by_user: user, chore_household: household, name: "Charge Villager Car") }

  before { user.update!(chore_household_id: household.id) }

  def completed!(at: Time.current, on: chore, by: user)
    ChoreCompletion.create!(
      chore: on, user: by, completed_at: at, day_key: ChoreDay.current(by, at: at),
    )
  end

  def condition(over = {})
    { find: :chore_completions, query: %q{name:"Charge Villager Car" is:today}, expect: :missing }.merge(over)
  end

  describe "the case it was built for" do
    it "fires while the chore is still outstanding" do
      expect(described_class.met?(condition, user: user)).to be(true)
    end

    it "goes quiet once the chore is done" do
      completed!

      expect(described_class.met?(condition, user: user)).to be(false)
    end

    # The other polarity is just as real: "once I've logged a workout, ..."
    it "reads the other way round when told to expect a hit" do
      expect(described_class.met?(condition(expect: :found), user: user)).to be(false)
      completed!
      expect(described_class.met?(condition(expect: :found), user: user)).to be(true)
    end
  end

  # A stored condition runs on days it wasn't written on, so `time>2026-08-12`
  # is useless in one — it's fixed to the day someone typed it.
  describe "relative windows" do
    it "ignores a completion from a previous day" do
      completed!(at: 3.days.ago)

      expect(described_class.met?(condition, user: user)).to be(true)
    end

    it "sees one from earlier in the week when asked for the week" do
      completed!(at: 3.days.ago)
      wide = condition(query: %q{name:"Charge Villager Car" is:week})

      expect(described_class.met?(wide, user: user)).to be(false)
    end

    # Chore days end at the household reset, not at midnight, so a chore ticked
    # off at 1am belongs to the evening it was part of — and the reset is 4am
    # WHERE THEY LIVE. The app sets no `config.time_zone`, so an evaluation that
    # didn't enter the person's zone would cut the day on UTC's 4am and file an
    # 11pm completion under tomorrow.
    it "counts a 1am completion against the day before, in their zone" do
      tz = ActiveSupport::TimeZone["America/Denver"]

      travel_to(tz.parse("2026-08-13 01:00")) do
        completed!
        expect(described_class.met?(condition, user: user)).to be(false)
      end
    end

    it "still files a late-evening completion under the day it belonged to" do
      tz = ActiveSupport::TimeZone["America/Denver"]

      travel_to(tz.parse("2026-08-12 23:30")) do
        completed!
        expect(described_class.met?(condition, user: user)).to be(false)
      end
    end

    # A window word nobody defined must narrow to nothing, never widen to
    # everything: a filter that silently matched all rows would read as
    # "condition satisfied" and fire the thing it was meant to hold back.
    it "matches nothing on a window word it doesn't know" do
      completed!
      nonsense = condition(query: %q{name:"Charge Villager Car" is:fortnight}, expect: :found)

      expect(described_class.met?(nonsense, user: user)).to be(false)
    end
  end

  describe "whose rows it can see" do
    # A shared chore is done when ANYONE does it. Scoped to one person, "is it
    # done yet" would nag whoever didn't happen to be the one who did it.
    it "counts a housemate's completion of a shared chore" do
      partner = create(:user)
      ChoreHouseholdMembership.create!(chore_household: household, user: partner, role: :member)
      partner.update!(chore_household_id: household.id)
      completed!(by: partner)

      expect(described_class.met?(condition, user: user)).to be(false)
    end

    # `Model.query` carries a comment saying it drops the current relation and
    # loses user filtering. Built on that, every condition would answer about
    # the whole database.
    it "cannot see another household's completions" do
      stranger = create(:user)
      away = ChoreHousehold.create!(name: "Elsewhere", owner_user: stranger)
      stranger.update!(chore_household_id: away.id)
      theirs = create(:chore, created_by_user: stranger, chore_household: away, name: "Charge Villager Car")
      completed!(on: theirs, by: stranger)

      expect(described_class.met?(condition, user: user)).to be(true)
    end
  end

  describe "refusing what it can't answer" do
    it "has no condition to check when nothing was given" do
      expect(described_class.met?(nil, user: user)).to be(true)
      expect(described_class.met?({}, user: user)).to be(true)
      expect(described_class.present?(nil)).to be(false)
    end

    it "refuses a set that isn't on the list" do
      expect { described_class.met?(condition(find: :squirrels), user: user) }.to raise_error(/no condition set/)
    end

    it "refuses a set with no query to search it with" do
      expect { described_class.met?(condition(query: " "), user: user) }.to raise_error(/needs a query/)
    end

    it "refuses a polarity that means nothing" do
      expect { described_class.met?(condition(expect: :maybe), user: user) }.to raise_error(/found or missing/)
    end

    it "keeps string keys working, since that's what jsonb hands back" do
      stored = { "find" => "chore_completions", "query" => %q{name:"Charge Villager Car" is:today}, "expect" => "missing" }

      expect(described_class.met?(stored, user: user)).to be(true)
    end
  end

  it "says what it's waiting on in words" do
    expect(described_class.describe(condition)).to include("no chore completions", %q{name:"Charge Villager Car"})
  end

  # The breaker syntax splits on whitespace, so an unquoted multi-word value is
  # a DIFFERENT query — and one that still runs, still returns rows, and looks
  # right. `name:Charge Villager Car` is `name:Charge` AND the loose words
  # "Villager" and "Car", each searched across every indexed column.
  #
  # Left unquoted, every spec in this file passed for the wrong reason: the
  # free-text halves matched the chore name on their own.
  describe "quoting" do
    def parse(q) = ::Tokenizing::Node.parse(q)

    it "reads a quoted value as one term" do
      node = parse(%q{name:"Charge Villager Car" is:today})

      expect(node.conditions.length).to eq(2)
      expect(node.conditions.first.conditions).to eq("Charge Villager Car")
    end

    it "splits an unquoted one into a term plus loose words" do
      node = parse("name:Charge Villager Car is:today")

      expect(node.conditions.first.conditions).to eq("Charge")
      expect(node.conditions).to include("Villager", "Car")
    end

    # The consequence, stated as behavior rather than as parse trees: an
    # unquoted condition answers about a chore it was never pointed at.
    it "matches the wrong chore when the value isn't quoted" do
      other = create(:chore, created_by_user: user, chore_household: household, name: "Charge Villager Bike")
      completed!(on: other)

      loose = condition(query: "name:Charge Villager is:today")
      tight = condition(query: %q{name:"Charge Villager Car" is:today})

      expect(described_class.met?(loose, user: user)).to be(false) # thinks the car is done
      expect(described_class.met?(tight, user: user)).to be(true)  # correctly, it isn't
    end
  end

  # Nothing here is about chores. Every set has to be able to answer a bare
  # query without blowing up in SQL — which is exactly how ChoreCompletion's
  # cross-table `name:` term was found to have been broken all along.
  describe "the whole whitelist" do
    it "can run a search against every set it offers" do
      described_class.sets.each do |set|
        expect { described_class.met?({ find: set, query: "anything", expect: :found }, user: user) }
          .not_to raise_error, "#{set} could not answer a plain query"
      end
    end

    it "scopes every set to this person's own rows" do
      described_class.sets.each do |set|
        scope = described_class::SETS.fetch(set).call(user)
        expect(scope.to_sql).to match(/WHERE/), "#{set} has no ownership filter at all"
      end
    end

    it "answers about action events, the same as anything else" do
      ActionEvent.create!(user: user, name: "workout", timestamp: Time.current)
      done = { find: :action_events, query: %q{name:"workout"}, expect: :found }

      expect(described_class.met?(done, user: user)).to be(true)
      expect(described_class.met?(done.merge(query: %q{name:"nap"}), user: user)).to be(false)
    end
  end

  # Anything they can wire, they can gate a schedule on: a sensor, a device, an
  # API, a calculation. The search sets can only ever cover rows in this app.
  describe "asking one of their own Jil functions" do
    let(:task) { instance_double(Task, name: "Is The Car Plugged In") }

    def jil(over = {})
      { kind: :jil, task: "Is The Car Plugged In", expect: :truthy }.merge(over)
    end

    def answers(value)
      allow(described_class).to receive(:resolve_task).and_return(task)
      allow(task).to receive(:execute).and_return(instance_double(Execution, result: value))
    end

    it "fires on a yes" do
      answers("true")

      expect(described_class.met?(jil, user: user)).to be(true)
    end

    it "holds on a no" do
      answers("false")

      expect(described_class.met?(jil, user: user)).to be(false)
    end

    it "reads the other polarity too" do
      answers("false")

      expect(described_class.met?(jil(expect: :falsy), user: user)).to be(true)
    end

    # A task that returns nothing has REPORTED nothing, and "no answer" must
    # never read as "yes, go ahead" — that's the direction that fires things
    # nobody asked for.
    it "treats silence as no" do
      answers("")

      expect(described_class.met?(jil, user: user)).to be(false)
    end

    it "treats a plain value as yes" do
      answers("72")

      expect(described_class.met?(jil, user: user)).to be(true)
    end

    %w[false 0 no off none unknown].each do |word|
      it "treats #{word.inspect} as no" do
        answers(word)

        expect(described_class.met?(jil, user: user)).to be(false)
      end
    end

    it "refuses a polarity that belongs to the other kind" do
      expect { described_class.met?(jil(expect: :missing), user: user) }.to raise_error(/truthy or falsy/)
    end

    # Names re-resolve on every run, the way routine steps and reminder commands
    # do, so a renamed task degrades to an unanswerable condition rather than
    # quietly running the nearest thing to it.
    it "raises rather than running the nearest match when the name stops resolving" do
      expect { described_class.met?(jil, user: user) }.to raise_error(/no Jil function matches/)
    end

    it "says what it's asking in words" do
      expect(described_class.describe(jil)).to include("Is The Car Plugged In", "true")
    end
  end

  # FeatureRequest 6, 4 Sep: "If I'm not home by 12:50, set Whisper Quiet for an
  # hour." Byte set the 12:50 part, said it had no home-away check wired, and
  # was told "that's not what's needed at all" - an unconditional version of a
  # conditional instruction is a different instruction.
  describe "where the person is" do
    let(:home_coord) { [40.48049, -111.99816] }

    def place!(name, coord)
      contact = Contact.create!(user: user, name: name)
      Address.create!(
        user: user, contact: contact, street: "#{name} St",
        lat: coord[0], lng: coord[1], primary: true,
      )
      contact
    end

    def at(coord)
      allow(::LocationCache).to receive(:last_coord).and_return(coord)
    end

    def where(over = {})
      { kind: :location, place: "home", expect: :at }.merge(over)
    end

    before do
      allow(user).to receive(:me?).and_return(true)
      place!("Home", home_coord)
    end

    it "says yes when they are there" do
      at(home_coord)

      expect(described_class.met?(where, user: user)).to be(true)
    end

    it "says no when they are not" do
      at([40.7608, -111.8910])

      expect(described_class.met?(where, user: user)).to be(false)
    end

    # The polarity the request was actually written in.
    it "reads the away side" do
      at([40.7608, -111.8910])
      expect(described_class.met?(where(expect: :away), user: user)).to be(true)

      at(home_coord)
      expect(described_class.met?(where(expect: :away), user: user)).to be(false)
    end

    # Same radius LocationCache and TravelResolver already treat as the house,
    # so "am I home" answers one way across the whole app rather than drawing a
    # second private boundary.
    it "counts the driveway as home" do
      at([home_coord[0] + 0.0005, home_coord[1]])

      expect(described_class.met?(where, user: user)).to be(true)
    end

    it "does not count the next suburb" do
      at([home_coord[0] + 0.02, home_coord[1]])

      expect(described_class.met?(where, user: user)).to be(false)
    end

    it "takes a place by name" do
      place!("The Gym", [40.5, -111.9])
      at([40.5, -111.9])

      expect(described_class.met?(where(place: "The Gym"), user: user)).to be(true)
      expect(described_class.met?(where, user: user)).to be(false)
    end

    # The same cascade `remind_when` resolves a travel watch through, so a
    # condition and a watch agree about where somewhere is.
    it "takes the way a person says a place" do
      place!("Chelsea", [40.5, -111.9])
      at([40.5, -111.9])

      expect(described_class.met?(where(place: "Chelsea's place"), user: user)).to be(true)
    end

    it "defaults to home when no place is named" do
      at(home_coord)

      expect(described_class.met?({ kind: :location }, user: user)).to be(true)
    end

    # Three ways of NOT KNOWING, and none of them may read as "no". "If I am
    # not home, do X" would otherwise fire hardest exactly when the app has no
    # idea where they are. The caller decides what an unanswerable condition
    # means - see ReminderFirer, which fires anyway and says so.
    it "raises rather than answering when nothing has reported a position" do
      at(nil)

      expect { described_class.met?(where, user: user) }.to raise_error(/no position/)
    end

    it "raises rather than answering when the place is nowhere it knows" do
      at(home_coord)

      expect { described_class.met?(where(place: "Narnia"), user: user) }.to raise_error(/Narnia/)
    end

    it "raises for anybody but the owner, whose position is the only one kept" do
      at(home_coord)
      allow(user).to receive(:me?).and_return(false)

      expect { described_class.met?(where, user: user) }.to raise_error(/owner/)
    end

    it "refuses a polarity that belongs to another kind" do
      expect { described_class.met?(where(expect: :truthy), user: user) }.to raise_error(/at or away/)
    end

    it "says what it is checking in words" do
      expect(described_class.describe(where(expect: :away))).to eq("only if you're not at home")
      expect(described_class.describe(where)).to eq("only if you're at home")
    end

    # Every other kind is recognised by its payload; this one has no required
    # payload at all, so it has to be recognised by its `kind`.
    it "is still a condition with nothing but a kind on it" do
      expect(described_class.present?({ kind: :location })).to be(true)
    end

    it "leaves an empty condition as no condition" do
      expect(described_class.present?({})).to be(false)
      expect(described_class.met?({}, user: user)).to be(true)
    end
  end
end

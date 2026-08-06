require "rails_helper"

# Not everyone in the household uses the whole app. Eve has no chores, no
# completions, and no pebbles, and no business firing commands at the owner's
# Mac. Before this, her companion was offered every tool regardless, and the
# Rules of the House taught chore-matching to every pet — so she'd have got
# something that kept reaching for a feature she doesn't have.
#
# Features are an ALLOW-list: a person holds a set, and anything outside it is
# unavailable. New PEOPLE get the default set at creation, so the fail-closed
# part lands on new FEATURES rather than on new accounts.
RSpec.describe Buddy::Features do
  let(:user)  { create(:user) }
  let(:convo) { user.byte_conversations.create!(mode: :buddy) }

  def revoke!(*features)
    user.revoke_buddy_features!(*features)
    user.reload
  end

  def grant!(*features)
    user.grant_buddy_features!(*features)
    user.reload
  end

  describe "which tools the model is even shown" do
    def offered
      Buddy::Tools.function_schemas(user: user).pluck(:name)
    end

    it "offers the default set to a new account, which is everything but the Mac" do
      expect(offered).to include(:complete_chore, :withdraw_pebbles, :log_event, :add_list_item)
      # Driving the owner's machine is his to hand out, not a starting condition.
      expect(offered).not_to include(:mac_command)
    end

    it "offers the Mac tool once it's granted" do
      grant!(:mac)

      expect(offered).to include(:mac_command)
    end

    it "drops a revoked feature's tools and leaves the rest alone" do
      revoke!(:chores)

      expect(offered).not_to include(
        :complete_chore, :create_chore, :edit_chore, :edit_chore_completion,
        :undo_chore_completion, :chore_progress, :withdraw_pebbles
      )
      expect(offered).to include(:log_event, :add_list_item, :set_timer, :add_agenda_item)
    end

    # The things that make a companion a companion rather than a front-end for
    # one subsystem. There's no way to withhold these.
    it "keeps core tools even for someone holding nothing at all" do
      user.update!(buddy_features: [])

      expect(offered).to include(:set_timer, :remind_when, :undo, :check_weather, :run_routine)
    end

    # A system caller isn't a person to restrict — treating nil as "holds
    # nothing" would quietly strip every tool off the eval harness.
    it "gates nothing when there's no user to check" do
      expect(Buddy::Tools.function_schemas.length).to eq(Buddy::Tools.all.length)
    end
  end

  # The reason for inverting: a capability added later reaches nobody until
  # someone decides it should, rather than reaching everyone before anyone
  # considered whether it should.
  describe "a feature nobody has been granted yet" do
    before { stub_const("#{described_class}::SECTIONS", described_class::SECTIONS.merge(images: %i[recent_images])) }

    it "is off for a person whose grants predate it" do
      expect(described_class.enabled?(user, :images)).to be(false)
      expect(described_class.missing_for(user)).to include(:images)
    end

    it "hides its context sections until it's granted" do
      expect(described_class.hidden_sections(user)).to include(:recent_images)

      grant!(:images)

      expect(described_class.hidden_sections(user)).not_to include(:recent_images)
    end
  end

  describe "what get_context will return" do
    it "drops a missing feature's sections rather than returning them empty" do
      revoke!(:chores)

      context = Buddy::Context.build(user, convo)

      # An empty chores_pending_today would read as "nothing due today", which
      # is a different statement from "chores aren't part of your setup".
      expect(context).not_to have_key(:chores_pending_today)
      expect(context).not_to have_key(:chores_all)
      expect(context).not_to have_key(:pebble_balance)
      expect(context).to have_key(:lists)
    end

    it "leaves a missing section out of the tool's own enum" do
      revoke!(:chores)

      enum = Buddy::GPT::ContextTool.schema(user: user).dig(:parameters, :properties, :sections, :items, :enum)

      expect(enum).not_to include(:chores_all, :pebble_balance)
      expect(enum).to include(:lists, :today_agenda)
    end

    it "refuses a missing section even when it's asked for by name" do
      revoke!(:chores)

      result = JSON.parse(Buddy::GPT::ContextTool.new(user, convo).call("sections" => ["chores_all"]))

      expect(result).not_to have_key("chores_all")
    end
  end

  # The schema was never offered, so reaching either of these means the model
  # invented the name — or a saved routine outlived the feature it was built on.
  describe "a tool they don't hold, called anyway" do
    it "fails to resolve instead of running" do
      output = Buddy::GPT::Turn.resolve_tool(
        Buddy::Tools[:mac_command],
        { name: :mac_command, arguments: { "command" => "dark_monitors" } },
        user: user, conversation: convo,
      )

      expect(output[:status]).to eq("failed")
      expect(output[:error]).to match(/isn't something this person has set up/)
    end

    it "is dropped by the builder the same way an unknown tool is" do
      revoke!(:chores)
      message = convo.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "…")

      result = Buddy::ProposalBuilder.create(
        user:         user,
        byte_message: message,
        markers:      [{ tool_name: :complete_chore, payload: { chore: "dishes" } }],
      )

      expect(result[:action]).to be_nil
      expect(result[:auto_ran]).to be(false)
    end
  end

  # Eve is IN the chore household - chores get attributed to her - so her
  # context would otherwise carry the whole household's roster. A core tool with
  # an option that reaches into chores is the same leak by a side door:
  # remind_when's chore trigger would ping her when someone ELSE finished one.
  describe "a core tool with an option that reaches into a feature" do
    let(:tool) { Buddy::Tools[:remind_when] }

    def triggers
      Buddy::Tools.function_schemas(user: user)
        .find { |s| s[:name] == :remind_when }
        .dig(:parameters, :properties, :trigger, :enum)
    end

    it "keeps the tool but trims the option out of its enum" do
      revoke!(:chores)

      expect(Buddy::Tools.function_schemas(user: user).pluck(:name)).to include(:remind_when)
      expect(triggers).not_to include(:chore)
      expect(triggers).to include(:arrive, :depart, :deploy, :event, :agenda)
    end

    it "trims each option independently" do
      revoke!(:events, :agenda)

      expect(triggers).not_to include(:event, :agenda)
      expect(triggers).to include(:chore, :arrive)
    end

    it "leaves every option in place for someone holding them all" do
      expect(triggers).to include(:arrive, :depart, :chore, :event, :agenda, :deploy)
    end

    it "refuses the option server-side when the model asks for it anyway" do
      revoke!(:chores)

      output = Buddy::GPT::Turn.resolve_tool(
        tool,
        { name: :remind_when, arguments: { "text" => "floss", "trigger" => "chore", "target" => "Brush Teeth" } },
        user: user, conversation: convo,
      )

      expect(output[:status]).to eq("failed")
      expect(output[:error]).to match(/isn't part of this person's setup/)
    end

    it "drops the marker at the builder too" do
      revoke!(:chores)
      message = convo.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "…")

      result = Buddy::ProposalBuilder.create(
        user:         user,
        byte_message: message,
        markers:      [{ tool_name: :remind_when, payload: { text: "floss", trigger: "chore", target: "Brush Teeth" } }],
      )

      expect(result[:action]).to be_nil
    end
  end

  # The briefing is chore-led by design - pending chores ARE the answer to
  # "what's on today". Pointed at someone without them, that guidance names
  # sections that aren't in their context at all.
  describe "the daily briefing" do
    it "leads with chores for someone who has them" do
      seed = Buddy::TodayBriefing.send(:seed, user)

      expect(seed).to include("`chores_pending_today` is the pool")
      expect(seed).to include("`chores_hot_picks`")
    end

    it "drops the chore guidance entirely rather than softening it" do
      revoke!(:chores)

      seed = Buddy::TodayBriefing.send(:seed, user)

      expect(seed).not_to include("chores_pending_today")
      expect(seed).not_to include("chores_hot_picks")
      expect(seed).not_to include("chores_done_today")
      # The rest of the briefing is untouched.
      expect(seed).to include("`today_agenda`")
      expect(seed).to include("LEAD WITH what still needs to happen today")
    end
  end

  describe "what the prompt says about it" do
    it "tells the model plainly, in the person's own terms" do
      revoke!(:chores)

      prompt = Buddy::Personality.for(user, conversation: convo)

      expect(prompt).to include("What this person doesn't have")
      expect(prompt).to include("chores, completions, and pebbles")
      expect(prompt).to include("commands on the Mac")
      expect(prompt).to include("Don't offer it, don't ask about it")
    end

    it "says nothing at all for someone holding everything" do
      grant!(*described_class.all)

      expect(Buddy::Personality.for(user, conversation: convo)).not_to include("What this person doesn't have")
    end
  end

  describe "storing it" do
    it "is a data change, not a branch keyed on who someone is" do
      revoke!(:chores)
      expect(user.buddy_feature?(:chores)).to be(false)
      expect(user.buddy_feature?(:lists)).to be(true)

      grant!(:chores)
      expect(user.buddy_feature?(:chores)).to be(true)
    end

    it "hands a brand-new account the default set rather than nothing" do
      expect(create(:user).buddy_features).to match_array(described_class::DEFAULT.map(&:to_s))
    end

    it "ignores a name that isn't a real feature rather than half-granting something" do
      user.update!(buddy_features: ["nonsense"])

      expect(described_class.enabled_for(user.reload)).to be_empty
    end

    it "doesn't double up when the same feature is granted twice" do
      user.update!(buddy_features: [])
      grant!(:chores)
      grant!(:chores)

      expect(user.reload.buddy_features).to eq(["chores"])
    end
  end

  # Every tool has to land in a feature, or withholding one would quietly leave
  # a way back into it.
  it "accounts for every registered tool" do
    known   = described_class.all + [described_class::CORE]
    strays  = Buddy::Tools.all.reject { |tool| known.include?(tool[:feature]) }

    expect(strays.map { |t| [t[:name], t[:feature]] }).to be_empty
  end
end

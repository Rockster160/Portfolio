require "rails_helper"

# Asking WHICH ONE with the answers already on screen: the resolver refuses to
# guess, and the candidates come up as buttons with the question.
RSpec.describe Buddy::Disambiguation do
  let(:user)         { create(:user) }
  let(:conversation) { ByteConversation.create!(user: user, buddy_theme: :byte) }
  let!(:household)   { ChoreHousehold.create!(name: "Home", owner_user: user) }

  def chore!(name)
    create(:chore, created_by_user: user, chore_household: household, name: name)
  end

  def resolve(tool_name, arguments, convo: conversation)
    Buddy::GPT::Turn.resolve_call(
      Buddy::Tools[tool_name],
      { name: tool_name, arguments: arguments.stringify_keys },
      user: user, conversation: convo,
    )
  end

  def card
    ByteAction.where(user: user, tool_name: described_class::TOOL_NAME).last
  end

  describe "a chore name that matches more than one" do
    before do
      chore!("Light Load Dishes")
      chore!("Medium~Normal Load Dishes")
      chore!("Unload Dishwasher")
    end

    it "puts the candidates up as buttons and completes nothing on its own" do
      expect { resolve(:complete_chore, { chore: "load dishwasher" }) }
        .not_to(change(ChoreCompletion, :count))

      expect(card).to be_present
      expect(card.buttons.length).to be >= 2
      expect(card.multi_select).to be(false)
      expect(card.tool_input["tool"]).to eq("complete_chore")
      expect(card.tool_input["arg"]).to eq("chore")
    end

    it "runs the chore they tap, with no model turn behind it" do
      resolve(:complete_chore, { chore: "load dishwasher" })
      action = card
      button = action.buttons.find { |b| b["value"] == "Light Load Dishes" }

      expect { described_class.chose!(action, button) }.to change(ChoreCompletion, :count).by(1)
      expect(ChoreCompletion.last.chore.name).to eq("Light Load Dishes")
    end
  end

  it "offers the one candidate as a button rather than making them retype it" do
    chore!("Light Load Dishes")
    resolve(:complete_chore, { chore: "load dishwasher" })

    expect(card.buttons.pluck("value")).to eq(["Light Load Dishes"])
  end

  it "answers in prose when nothing is close at all" do
    chore!("Brush Teeth")
    output, = resolve(:complete_chore, { chore: "helicopter" })

    expect(card).to be_nil
    expect(output.to_s).to include("no chore matching")
  end

  # A routine or an eval sweep has nowhere to put buttons, and then the
  # sentence is still the best answer available.
  it "falls back to the sentence when there is no conversation" do
    chore!("Light Load Dishes")
    chore!("Medium~Normal Load Dishes")
    chore!("Unload Dishwasher")

    output, = resolve(:complete_chore, { chore: "load dishwasher" }, convo: nil)

    expect(card).to be_nil
    expect(output.to_s).to include("Light Load Dishes", "Unload Dishwasher")
  end

  describe "two lists whose names both carry what they said" do
    it "asks which, rather than letting the ordering decide" do
      create(:list, name: "Grocery Staples").tap { |l| user.user_lists.create!(list: l) }
      create(:list, name: "Grocery Costco").tap { |l| user.user_lists.create!(list: l) }

      resolve(:add_list_item, { list: "grocery", item: "oat milk" })

      expect(card).to be_present
      expect(card.buttons.pluck("value")).to contain_exactly("Grocery Staples", "Grocery Costco")
      expect(card.tool_input["arg"]).to eq("list")
    end

    it "takes a name that resolves outright over one that only starts the same" do
      create(:list, name: "Grocery").tap { |l| user.user_lists.create!(list: l) }
      create(:list, name: "Grocery Staples").tap { |l| user.user_lists.create!(list: l) }

      resolve(:add_list_item, { list: "Grocery", item: "oat milk" })

      expect(card).to be_nil
    end

    it "leaves a single match alone" do
      create(:list, name: "Grocery").tap { |l| user.user_lists.create!(list: l) }

      resolve(:add_list_item, { list: "grocery", item: "oat milk" })

      expect(card).to be_nil
    end
  end

  describe "two different things on the calendar" do
    let(:agenda) { create(:agenda, user: user) }

    it "asks which, and says when each one is" do
      create(
        :agenda_item, agenda: agenda, name: "Board Meeting",
        start_at: 2.days.from_now, end_at: 2.days.from_now + 1.hour
      )
      create(
        :agenda_item, agenda: agenda, name: "Team Meeting",
        start_at: 3.days.from_now, end_at: 3.days.from_now + 1.hour
      )

      resolve(:edit_agenda_item, { item: "meeting", starts_at: "4pm" })

      expect(card).to be_present
      expect(card.buttons.pluck("value")).to contain_exactly("Board Meeting", "Team Meeting")
      expect(card.buttons.pluck("description")).to all(be_present)
    end

    # The same thing on four dates has one right answer and it is the soonest.
    it "does not ask about one recurring thing matching itself" do
      3.times { |i|
        create(
          :agenda_item, agenda: agenda, name: "Dentist",
          start_at: (i + 1).weeks.from_now, end_at: (i + 1).weeks.from_now + 1.hour
        )
      }

      resolve(:edit_agenda_item, { item: "dentist", starts_at: "4pm" })

      expect(card).to be_nil
    end
  end

  describe "two boxes with the same name" do
    before { user.update!(buddy_features: Buddy::Features::DEFAULT) }

    let!(:garage)   { create(:box, user: user, name: "Garage") }
    let!(:basement) { create(:box, user: user, name: "Basement") }

    it "offers the handle, because that is what tells them apart" do
      create(:box, user: user, name: "Smellies", parent: garage)
      create(:box, user: user, name: "Smellies", parent: basement)

      resolve(:remove_inventory_item, { item: "Smellies" })

      expect(card).to be_present
      expect(card.buttons.pluck("value")).to all(start_with("#"))
      expect(card.buttons.pluck("description")).to include("in Garage", "in Basement")
    end

    it "rebuilds the call against the box they picked" do
      one = create(:box, user: user, name: "Smellies", parent: garage)
      create(:box, user: user, name: "Smellies", parent: basement)

      resolve(:remove_inventory_item, { item: "Smellies" })
      action = card
      button = action.buttons.find { |b| b["value"] == "##{one.param_key}" }

      described_class.chose!(action, button)

      expect(action.byte_conversation.byte_messages.last.metadata["buttons"].first["payload"]["item"])
        .to eq("##{one.param_key}")
    end
  end
end

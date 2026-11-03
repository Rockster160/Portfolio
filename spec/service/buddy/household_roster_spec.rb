require "rails_helper"

# Who is reachable by relay, generated from the same household membership the
# tools resolve against, and shipped in every prompt.
RSpec.describe "Buddy household roster" do
  let(:rocco)   { create(:user) }
  let(:chelsea) { create(:user) }
  let(:eve)     { create(:user) }
  let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: rocco) }
  let!(:convo) { ByteConversation.create!(user: rocco, mode: :buddy, name: "Buddy") }

  before do
    # ChoreHousehold auto-adds its owner as a manager member.
    [chelsea, eve].each { |u|
      ChoreHouseholdMembership.create!(chore_household: household, user: u, role: :member)
      u.update!(chore_household_id: household.id)
    }
    rocco.update!(chore_household_id: household.id)
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(WebPushNotifications).to receive(:send_to_byte)
    allow(ByteConversation).to receive(:default_theme_for) { |u|
      { chelsea => "moss", eve => "suki" }.fetch(u, "byte")
    }
  end

  def roster_for(user)
    Buddy::Personality.household_block(user)
  end

  describe "the block itself" do
    it "names everyone else in the house and which companion they have, but not themselves", :aggregate_failures do
      block = roster_for(rocco)

      expect(block).to include(chelsea.first_name, "Moss")
      expect(block).to include(eve.first_name, "Suki")
      expect(block).not_to include("**#{rocco.first_name}**")
    end

    it "reaches the real system prompt, not just the helper" do
      prompt = Buddy::Personality.for(rocco, conversation: convo)

      expect(prompt).to include("Who else is in the house", eve.first_name)
    end

    it "says nothing for someone with no household, or who can't relay at all", :aggregate_failures do
      expect(roster_for(create(:user))).to be_nil

      rocco.revoke_buddy_features!(:relay)

      expect(roster_for(rocco.reload)).to be_nil
    end
  end

  # The roster is only worth anything if it never names someone the tool would
  # then refuse, so both read the same membership.
  describe "the roster and the tools agree" do
    it "resolves every name it advertises, and nobody outside the house", :aggregate_failures do
      outsider = create(:user)
      ctx = Buddy::ToolContext.new(rocco, conversation: convo)
      block = roster_for(rocco)

      [chelsea, eve].each { |u|
        expect(block).to include(u.first_name)
        expect(ctx.resolve_household_user(u.first_name)).to eq(u)
      }
      expect(roster_for(rocco)).not_to include(outsider.first_name)
      expect(ctx.resolve_household_user(outsider.first_name)).to be_nil
    end
  end

  describe "relaying past the partner pair" do
    def send!(from:, to:, text:)
      conversation = ByteConversation.where(user: from, mode: :buddy).first ||
        ByteConversation.create!(user: from, mode: :buddy, name: "Buddy")
      tool = Buddy::Tools[:message_partner]
      ctx  = Buddy::ToolContext.new(from, conversation: conversation)
      confirm = tool[:confirm].call({ to: to.username, message: text }, ctx)
      tool[:execute].call({ to: to.username, message: text }.merge(confirm[:resolved]), ctx)
    end

    it "carries a note to the third person and back the other way", :aggregate_failures do
      send!(from: rocco, to: eve, text: "we're leaving at six")

      relay = BuddyRelay.last
      expect(relay).to have_attributes(from_user: rocco, to_user: eve, status: "delivered")
      expect(eve.byte_conversations.first.byte_messages.pluck(:body)).to include("we're leaving at six")

      send!(from: eve, to: chelsea, text: "the pantry's done")

      relay = BuddyRelay.last
      expect(relay).to have_attributes(from_user: eve, to_user: chelsea, status: "delivered")
      expect(chelsea.byte_conversations.first.byte_messages.pluck(:body)).to include("the pantry's done")
    end
  end
end

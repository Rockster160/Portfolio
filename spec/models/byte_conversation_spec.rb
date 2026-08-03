# == Schema Information
#
# Table name: byte_conversations
#
#  id                :bigint           not null, primary key
#  user_id           :bigint           not null
#  name              :string
#  mode              :integer          default("claude"), not null
#  archived          :boolean          default(FALSE), not null
#  metadata          :jsonb            not null
#  last_message_at   :datetime
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  buddy_theme       :string           default("byte"), not null
#  buddy_expression  :string           default("neutral"), not null
#  buddy_sleep_until :datetime
#  buddy_memories    :text
#
require "rails_helper"

RSpec.describe ByteConversation, type: :model do
  let(:user) { User.me }

  it "assigns a default conversation to messages that don't specify one" do
    msg = user.byte_messages.create!(body: "hi")
    expect(msg.byte_conversation).to be_present
    expect(msg.byte_conversation.user_id).to eq(user.id)
  end

  it "returns a stable default per-user across calls" do
    a = ByteConversation.default_for(user)
    b = ByteConversation.default_for(user)
    expect(a.id).to eq(b.id)
  end

  # The buddy:eval harness writes into its own thread, which leaves it with the
  # newest last_message_at after every run — so without this, running an eval
  # would change which thread the app opens into and where a conversation-less
  # message lands.
  describe "eval threads" do
    let!(:real_convo) { user.byte_conversations.create!(name: "Byte", mode: :buddy) }
    let!(:eval_convo) {
      user.byte_conversations.create!(name: "Eval · Byte", mode: :buddy, metadata: { "eval" => true })
    }

    before { eval_convo.touch_activity(1.minute.from_now) }

    it "never becomes the default, even when it is the most recent" do
      expect(user.byte_conversations.active.ordered.first).to eq(eval_convo)
      expect(ByteConversation.default_for(user)).to eq(real_convo)
    end

    it "does not catch a message that arrives without a conversation" do
      msg = user.byte_messages.create!(body: "hi")

      expect(msg.byte_conversation).to eq(real_convo)
    end

    it "still counts toward spend reporting — it is the same money" do
      BuddyUsage.create!(
        user:          user,
        kind:          :eval,
        model:         "gpt-5.4-mini",
        input_tokens:  100,
        output_tokens: 10,
        cost_micros:   500,
      )

      expect(BuddyUsage.since(1.hour.ago).spend_micros).to eq(500)
    end

    it "is still listed, since reading the back-and-forth is the point" do
      expect(user.byte_conversations.active.ordered).to include(eval_convo)
      expect(eval_convo.eval?).to be(true)
      expect(real_convo.eval?).to be(false)
    end
  end

  it "exposes mode as an integer-backed enum" do
    convo = user.byte_conversations.create!(name: "shell fun", mode: :bash)
    expect(convo.mode).to eq("bash")
    expect(convo.bash?).to be(true)
  end

  it "bumps last_message_at when a message is created" do
    convo = user.byte_conversations.create!(name: "chat", mode: :claude)
    expect(convo.last_message_at).to be_nil
    convo.byte_messages.create!(user: user, body: "yo", direction: :inbound, state: :delivered)
    convo.reload
    expect(convo.last_message_at).to be_present
  end

  it "orders active conversations by most-recent activity" do
    older = user.byte_conversations.create!(name: "older", mode: :claude, last_message_at: 2.hours.ago)
    newer = user.byte_conversations.create!(name: "newer", mode: :claude, last_message_at: 5.minutes.ago)
    expect(user.byte_conversations.active.ordered.map(&:id).first(2)).to eq([newer.id, older.id])
  end

  it "excludes archived conversations from the active scope" do
    live     = user.byte_conversations.create!(name: "live",     mode: :claude)
    archived = user.byte_conversations.create!(name: "archived", mode: :claude, archived: true)
    expect(user.byte_conversations.active).to include(live)
    expect(user.byte_conversations.active).not_to include(archived)
  end

  it "returns a mode-derived display name when unnamed" do
    convo = user.byte_conversations.create!(mode: :bash)
    expect(convo.display_name).to eq("Terminal")
  end

  it "names an unnamed buddy conversation after the Buddy, per theme" do
    convo = user.byte_conversations.create!(mode: :buddy)
    expect(convo.buddy?).to be(true)

    convo.update!(buddy_theme: "byte")
    expect(convo.display_name).to eq("Byte")

    convo.update!(buddy_theme: "moss")
    expect(convo.display_name).to eq("Moss")

    convo.update!(buddy_theme: "suki")
    expect(convo.display_name).to eq("Suki")
  end

  describe ".default_theme_for" do
    it "seeds Suki for Eve, Moss for Chelsea, and Byte for everyone else" do
      expect(described_class.default_theme_for(instance_double(User, id: 4))).to eq(:suki)
      expect(described_class.default_theme_for(instance_double(User, id: 58_128))).to eq(:moss)
      expect(described_class.default_theme_for(instance_double(User, id: 999_999))).to eq(:byte)
      expect(described_class.default_theme_for(nil)).to eq(:byte)
    end
  end

  describe ".display_name_for" do
    it "maps each theme to its pet name and falls back to Byte" do
      expect(described_class.display_name_for("suki")).to eq("Suki")
      expect(described_class.display_name_for("moss")).to eq("Moss")
      expect(described_class.display_name_for("byte")).to eq("Byte")
      expect(described_class.display_name_for("nonsense")).to eq("Byte")
    end
  end
end

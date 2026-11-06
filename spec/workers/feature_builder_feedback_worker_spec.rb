require "rails_helper"

RSpec.describe FeatureBuilderFeedbackWorker do
  let(:user)    { User.me }
  let(:builder) { user.byte_conversations.create!(mode: :builder, last_message_at: Time.current) }

  before { allow(described_class).to receive(:perform_in) }

  def prompts
    builder.byte_messages.where("metadata->>'pr_feedback_prompt' = 'true'")
  end

  it "sends the gathered feedback to the session as one hidden message" do
    travel_to(1.minute.ago) {
      FeatureBuilder.feedback_for!(builder, "Rename the method", nil)
      FeatureBuilder.feedback_for!(builder, "Add a spec", nil)
    }

    described_class.new.perform(builder.id)

    expect(prompts.count).to eq(1)
    expect(prompts.first.body).to include("Rename the method", "Add a spec")
    expect(prompts.first.metadata["hidden"]).to be(true)
  end

  it "sends nothing when there's nothing new" do
    described_class.new.perform(builder.id)

    expect(prompts).to be_empty
  end
end

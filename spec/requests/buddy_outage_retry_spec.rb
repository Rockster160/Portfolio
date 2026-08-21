require "rails_helper"

RSpec.describe "Retrying a message that didn't go through", type: :request do
  let(:user) { User.me }
  let!(:convo) {
    user.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: Time.current)
  }

  def sign_in_as(target)
    post login_path, params: { user: { username: target.username, password: "password123" } }
  end

  def message(state:, direction: :outbound)
    convo.byte_messages.create!(user: user, direction: direction, state: state, body: "are you there?")
  end

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(SlackNotifier).to receive(:notify)
    user.update!(password: "password123", password_confirmation: "password123")
    sign_in_as(user)
    Buddy::Outage.clear!
  end

  after { Buddy::Outage.clear! }

  around { |example| Sidekiq::Testing.fake! { example.run } }

  it "sends a failed message of your own back through" do
    msg = message(state: :failed)

    post byte_message_retry_path(msg)

    expect(response).to have_http_status(:ok)
    expect(msg.reload.state).not_to eq("failed")
  end

  it "clears the outage marker so the bubble stops saying undelivered" do
    Buddy::Outage.down!(detail: "no credits")
    msg = message(state: :failed)
    msg.update!(metadata: { "failure" => Buddy::Outage::REASON })

    post byte_message_retry_path(msg)

    # Still down, so it fails again — but under a fresh failure, not the stale one.
    expect(msg.reload.metadata["failure"]).to eq(Buddy::Outage::REASON)
    expect(msg.state).to eq("failed")
  end

  it "refuses a message that didn't fail" do
    msg = message(state: :delivered)

    post byte_message_retry_path(msg)

    expect(response).to have_http_status(:unprocessable_entity)
  end

  # Buddy's own reply is not yours to re-send.
  it "refuses one of Buddy's" do
    msg = message(state: :failed, direction: :inbound)

    post byte_message_retry_path(msg)

    expect(response).to have_http_status(:unprocessable_entity)
  end
end

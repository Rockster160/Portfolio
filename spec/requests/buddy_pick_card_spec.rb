require "rails_helper"

# Tapping "which one did you mean". The card is the answer, so the tap runs the
# original call there and then — no model turn behind it, because the answer was
# decided the moment they pressed it and spending a round trip on having the
# model re-say it costs money and invites a different answer.
RSpec.describe "Buddy pick-one card", type: :request do
  # Byte is not a general-user surface (User#byte_access?), so the tap has to
  # come from someone who can open it at all.
  let(:user) { User.me }
  let(:action) { ByteAction.where(user: user, tool_name: Buddy::Disambiguation::TOOL_NAME).last }
  let(:conversation) { ByteConversation.create!(user: user, buddy_theme: :byte) }
  let(:household)    { user.chore_household || ChoreHousehold.create!(name: "Home", owner_user: user) }

  before do
    user.update!(password: "password123", password_confirmation: "password123")
    ["Light Load Dishes", "Medium~Normal Load Dishes", "Unload Dishwasher"].each { |name|
      create(:chore, created_by_user: user, chore_household: household, name: name)
    }
    Buddy::GPT::Turn.resolve_call(
      Buddy::Tools[:complete_chore],
      { name: :complete_chore, arguments: { "chore" => "load dishwasher" } },
      user: user, conversation: conversation,
    )
    post login_path, params: { user: { username: user.username, password: "password123" } }
  end

  def tap!(value)
    post byte_action_respond_path(request_id: action.request_id), params: { value: value }
  end

  it "runs the chore they chose" do
    expect { tap!("Light Load Dishes") }.to change(ChoreCompletion, :count).by(1)

    expect(response).to have_http_status(:ok)
    expect(ChoreCompletion.last.chore.name).to eq("Light Load Dishes")
  end

  it "marks the card decided so it stops asking" do
    tap!("Light Load Dishes")

    expect(action.reload).to be_decided
    expect(action.decision["value"]).to eq("Light Load Dishes")
  end

  # `apply_decision!` takes the action out of `pending` on the first tap, which
  # is what stops a double tap logging the chore twice.
  it "does nothing on a second tap" do
    tap!("Light Load Dishes")

    expect { tap!("Unload Dishwasher") }.not_to(change(ChoreCompletion, :count))
    expect(response).to have_http_status(:conflict)
  end

  # By value, never by index: a stale card must not run whatever now sits in
  # that position.
  it "refuses a value the card never offered" do
    expect { tap!("Take Out The Bins") }.not_to(change(ChoreCompletion, :count))

    expect(response).to have_http_status(:unprocessable_entity)
    expect(action.reload).to be_pending
  end
end

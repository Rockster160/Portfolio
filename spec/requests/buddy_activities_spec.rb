require "rails_helper"

RSpec.describe "Buddy activity", type: :request do
  let(:user) { User.me }
  let(:password) { "password123" }
  let(:convo) { ByteConversation.create!(user: user, mode: :buddy, name: "Kitchen") }

  before { allow(ActionEventNotifier).to receive(:notify) }

  def sign_in(as)
    as.update!(password: password, password_confirmation: password)
    post "/login", params: { user: { username: as.username, password: password } }
  end

  def logged(owner, name)
    ctx = Buddy::ToolContext.new(owner, conversation: (convo if owner == user))
    outcome = Buddy::Tools.dispatch(Buddy::Tools[:log_event], { name: name }, ctx)
    BuddyActivity.find(outcome[:activity_id])
  end

  it "lists their own activity newest first and undoes one", :aggregate_failures do
    older = logged(user, "Sandbox coffee")
    newer = logged(user, "Sandbox tea")
    logged(create(:user), "Sandbox stranger")
    sign_in(user)

    get "/buddy/activity"
    expect(response).to have_http_status(:ok)
    expect(response.body.index("Sandbox tea")).to be < response.body.index("Sandbox coffee")
    expect(response.body).not_to include("Sandbox stranger")
    expect(response.body).to include(buddy_activity_undo_path(older), buddy_activity_undo_path(newer))

    post buddy_activity_undo_path(newer)
    expect(response).to redirect_to(buddy_activities_path)
    expect(newer.reload.undone_at).to be_present
    expect(ActionEvent.where(user: user).pluck(:name)).to eq(["Sandbox coffee"])

    get "/buddy/activity", params: { undoable: 1 }
    expect(response.body).not_to include(buddy_activity_undo_path(newer))
  end

  it "does not undo someone else's" do
    theirs = logged(create(:user), "Sandbox stranger")
    sign_in(user)

    post buddy_activity_undo_path(theirs)

    expect(theirs.reload.undone_at).to be_nil
  end

  it "is closed to an account without Buddy" do
    sign_in(create(:user))

    get "/buddy/activity"

    expect(response).to have_http_status(:forbidden)
  end
end

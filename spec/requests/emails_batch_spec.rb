require "rails_helper"

RSpec.describe "Email batch changes", type: :request do
  let(:user) { create(:user, role: :admin) }
  let(:other_user) { create(:user) }

  def email!(owner: user, **attrs)
    Email.create!(
      user:               owner,
      mail_id:            "rb-#{SecureRandom.hex(4)}",
      timestamp:          1.day.ago,
      direction:          :inbound,
      inbound_mailboxes:  [{ address: "rocco@rdjn.com" }],
      outbound_mailboxes: [{ address: "a@b.com" }],
      subject:            "Hello",
      blurb:              "",
      **attrs,
    )
  end

  before { post login_path, params: { user: { username: user.username, password: "password123" } } }

  it "applies to the ids sent, and never to someone else's" do
    mine = email!
    left = email!
    theirs = email!(owner: other_user)

    post batch_emails_path, params: { operation: :read, ids: [mine.id, theirs.id] }, as: :json

    expect(response.parsed_body["count"]).to eq(1)
    expect(mine.reload).to be_read
    expect(left.reload).not_to be_read
    expect(theirs.reload).not_to be_read
  end

  it "applies to everything the search matches with all" do
    tagged = email!(outbound_mailboxes: [{ address: "orders@amazon.com" }])
    untouched = email!

    post batch_emails_path, params: { operation: :add_tags, tags: "Receipts", all: true, q: "from:amazon.com" },
      as: :json

    expect(tagged.reload.tags).to eq(["Receipts"])
    expect(untouched.reload.tags).to eq([])
  end

  it "refuses an unknown operation" do
    post batch_emails_path, params: { operation: :destroy, ids: [email!.id] }, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "lists search results" do
    email!(subject: "Match me")

    get emails_path, params: { q: "in:all subject:match" }

    expect(response.body).to include("Match me")
  end

  it "saves tags and the read flag from a single email" do
    email = email!

    patch email_path(email), params: { email: { tag_list: "a, b", read: "true" } }

    expect(email.reload.tags).to eq(["a", "b"])
    expect(email).to be_read
  end

  it "unarchives from a form param" do
    email = email!(archived_at: 1.hour.ago)

    patch email_path(email), params: { email: { archived: "false" } }

    expect(email.reload).not_to be_archived
  end
end

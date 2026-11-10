require "rails_helper"

# Something done to a mail in Mail.app that only the Mac can see. Rails keeps
# the mail and fires the `mail` trigger; what the event turns into is a task's.
RSpec.describe "POST /webhooks/byte/mail", type: :request do
  let!(:user) { create(:user) }
  let(:raw) {
    [
      "From: Cordelia Vance <cordelia@icapital.com>",
      "To: Rocco Nicholls <rocco@example.com>",
      "Subject: Contract to sign",
      "Message-ID: <contract-1@icapital.com>",
      "Date: #{1.day.ago.rfc2822}",
      "Content-Type: text/plain; charset=UTF-8",
      "",
      "Please sign by Friday.\n",
    ].join("\n")
  }

  before do
    allow(ByteLocal).to receive(:valid_secret?).and_return(true)
    user.tasks.create!(
      name:     "Flagged Mail Listener",
      listener: "mail:action::flagged",
      enabled:  true,
      code:     "d = Global.input_data()::Hash\n",
    )
  end

  def fired = user.executions.where(trigger_scope: :mail).map(&:input_data)

  def post_mail(**overrides)
    post "/webhooks/byte/mail", params: {
      user_id: user.id,
      event:   :flagged,
      raw_b64: Base64.encode64(raw),
    }.merge(overrides)
  end

  it "refuses without the shared secret" do
    allow(ByteLocal).to receive(:valid_secret?).and_return(false)

    post_mail

    expect(response).to have_http_status(:unauthorized)
    expect(user.emails.count).to be_zero
    expect(fired).to be_empty
  end

  it "keeps the mail and fires the trigger with a link to it", :aggregate_failures do
    post_mail

    email = user.emails.order(:id).last
    expect(response).to have_http_status(:created)
    expect(response.parsed_body["email_id"]).to eq(email.id)
    expect(email.mail_blob).to be_attached
    expect(fired).to contain_exactly(
      hash_including(
        "action"  => "flagged",
        "id"      => email.id,
        "subject" => "Contract to sign",
        "from"    => "Cordelia Vance <cordelia@icapital.com>",
        "url"     => "http://localhost:3141/emails/#{email.id}",
      ),
    )
  end

  it "reuses the row for a mail Ardesian already has" do
    post_mail
    post_mail

    expect(user.emails.where(mail_id: "contract-1@icapital.com").count).to eq(1)
    expect(fired.size).to eq(2)
  end

  it "names a subjectless mail rather than leaving it blank" do
    post_mail(raw_b64: Base64.encode64(raw.sub("Subject: Contract to sign\n", "")))

    expect(fired).to contain_exactly(hash_including("subject" => "(no subject)"))
  end

  it "fires nothing when there is no mail to keep" do
    post_mail(raw_b64: "")

    expect(response).to have_http_status(:unprocessable_entity)
    expect(fired).to be_empty
  end
end

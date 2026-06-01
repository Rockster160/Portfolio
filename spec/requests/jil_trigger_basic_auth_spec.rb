require "rails_helper"

RSpec.describe "POST /jil/trigger/:trigger with HTTP Basic auth", type: :request do
  let(:user) { User.me }
  let(:password) { "password123" }
  let(:basic_auth) { Base64.encode64("#{user.username}:#{password}").strip }
  let(:auth_headers) { { "Authorization" => "Basic #{basic_auth}" } }

  before do
    user.update!(password: password, password_confirmation: password)
    user.tasks.destroy_all
  end

  it "fires the task that matches the trigger scope" do
    user.tasks.create!(
      name:     "Basic Auth Listener",
      listener: "basic_auth_demo",
      enabled:  true,
      code:     <<~JIL.strip,
        ok = Global.print("ran")::String
      JIL
    )

    expect {
      post "/jil/trigger/basic_auth_demo",
        params: { payload: { foo: "bar" } },
        headers: auth_headers, as: :json
    }.to change { user.executions.count }.by(1)

    expect(response).to have_http_status(:ok)
    execution = user.executions.last
    expect(execution.trigger_scope).to eq("basic_auth_demo")
    expect(execution.auth_type).to eq("userpass")
    expect(execution.auth_type_id).to eq(user.id)
  end
end

require "rails_helper"

RSpec.describe Jil::Methods::Oauth do
  let(:user) { create(:user) }

  def run(code)
    Jil::Executor.call(user, code)
  end

  def connect(secret)
    run(<<~JIL)
      oauth = Oauth.connection("spotify_api", "https://a.test/authorize", "https://a.test/token", "https://api.a.test/v1", "scope-a", "client-123", "#{secret}")::Oauth
      url = oauth.auth_url()::String
    JIL
  end

  it "saves the client secret into secrets and keeps it out of the run" do
    exe = connect("shh-its-secret")

    expect(exe.ctx[:error]).to be_blank
    expect(user.secrets.named("oauth:spotify_api:client_secret").value).to eq("shh-its-secret")
    expect(exe.ctx[:vars].to_s).not_to include("shh-its-secret")
    expect(exe.ctx.dig(:vars, :url, :value)).to include("client_id=client-123")
  end

  it "uses the saved secret when the task leaves it blank" do
    connect("shh-its-secret")
    connect("")

    expect(user.secrets.named("oauth:spotify_api:client_secret").value).to eq("shh-its-secret")
  end
end

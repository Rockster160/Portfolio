require "rails_helper"

RSpec.describe Apns do
  let(:production_key) { OpenSSL::PKey::EC.generate("prime256v1") }
  let(:sandbox_key) { OpenSSL::PKey::EC.generate("prime256v1") }
  let(:env) {
    {
      "PORTFOLIO_APNS_KEY"            => production_key.to_pem.gsub("\n", "\\n"),
      "PORTFOLIO_APNS_KEY_ID"         => "PRODKEY123",
      "PORTFOLIO_APNS_SANDBOX_KEY"    => sandbox_key.to_pem,
      "PORTFOLIO_APNS_SANDBOX_KEY_ID" => "SANDKEY123",
      "PORTFOLIO_APNS_TEAM_ID"        => "TEAM123456",
    }
  }

  before do
    described_class.instance_variable_set(:@provider_tokens, nil)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:fetch).and_call_original
    env.each { |name, value|
      allow(ENV).to receive(:[]).with(name).and_return(value)
      allow(ENV).to receive(:fetch).with(name, anything).and_return(value)
    }
  end

  after { described_class.instance_variable_set(:@provider_tokens, nil) }

  def signed_with(token, key)
    JWT.decode(token, key, true, algorithm: "ES256")
  rescue JWT::VerificationError
    nil
  end

  it "signs each environment's pushes with that environment's key", :aggregate_failures do
    production = described_class.send(:provider_token, :production)
    sandbox = described_class.send(:provider_token, :development)

    expect(signed_with(production, production_key)&.last).to include("kid" => "PRODKEY123")
    expect(signed_with(sandbox, sandbox_key)&.last).to include("kid" => "SANDKEY123")
    expect(signed_with(sandbox, production_key)).to be_nil
  end

  it "signs sandbox pushes with the production key when there is no sandbox key" do
    env.merge!("PORTFOLIO_APNS_SANDBOX_KEY" => nil, "PORTFOLIO_APNS_SANDBOX_KEY_ID" => nil)
    env.each { |name, value|
      allow(ENV).to receive(:[]).with(name).and_return(value)
      allow(ENV).to receive(:fetch).with(name, anything).and_return(value)
    }

    sandbox = described_class.send(:provider_token, :development)

    expect(signed_with(sandbox, production_key)&.last).to include("kid" => "PRODKEY123")
  end
end

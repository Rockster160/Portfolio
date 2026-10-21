require "rails_helper"

RSpec.describe Jil::Methods::String do
  let(:user) { FactoryBot.create(:user) }

  describe ".hmac" do
    it "is the hex HMAC-SHA256 of the string, keyed with the argument" do
      code = <<~JIL
        body = String.new("hello")::String
        digest = body.hmac("key")::String
        out = Global.return(digest)::String
      JIL

      expect(Jil::Executor.call(user, code).result).to eq(
        OpenSSL::HMAC.hexdigest("SHA256", "key", "hello"),
      )
    end
  end
end

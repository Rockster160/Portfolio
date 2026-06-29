require "rails_helper"

# Reproduces the bug where external Run-button POSTs (which arrive as string-keyed
# hashes after Sidekiq's JSON roundtrip) silently delivered nil to
# Global.functionParams positional binders that look up dig(:params).
RSpec.describe Jil::Executor do
  let(:user) { User.me }

  let(:code) {
    <<~'JIL'
      params = Global.functionParams({
        color = Keyword.Item()::String
      })::Array
      out = Global.return(color)::String
    JIL
  }

  it "binds positional args from a string-keyed input_data hash" do
    string_keyed = { "params" => ["White"], "Color" => "White" }
    exe = described_class.call(user, code, string_keyed)
    expect(exe.result).to eq("White")
  end

  it "binds positional args from a symbol-keyed input_data hash" do
    symbol_keyed = { params: ["Blue"] }
    exe = described_class.call(user, code, symbol_keyed)
    expect(exe.result).to eq("Blue")
  end

  it "binds NamedArg lookups from a string-keyed input_data hash" do
    named_code = <<~'JIL'
      params = Global.functionParams({
        person = Keyword.NamedArg("person")::String
      })::Array
      out = Global.return(person)::String
    JIL
    exe = described_class.call(user, named_code, { "person" => "Alice", "params" => ["Alice"] })
    expect(exe.result).to eq("Alice")
  end
end

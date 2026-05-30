require "rails_helper"

# Regression: commented lines inside `{...}` blocks used to yield `nil` into
# `evalargs`, which then exploded the receiver's `hash_wrap` with
# `TypeError: no implicit conversion of nil into Hash`. Now `evalargs` filters
# commented parsers out of nested arrays before evaluating.
RSpec.describe "Jil: commented lines inside blocks", type: :service do
  let(:user) { create(:user) }

  it "ignores a commented multi-line entry inside Hash.new" do
    code = <<~'JIL'
      map = Hash.new({
        # m_skip = Keyval.keyHash("Skip", {
          # skip_n = Hash.keyval("name", "Skip")::Keyval
        # })::Keyval
        m_keep = Keyval.keyHash("Keep", {
          keep_n = Hash.keyval("name", "Keep")::Keyval
        })::Keyval
      })::Hash
      ret = Global.return(map)::Hash
    JIL
    result = Jil::Executor.call(user, code)
    expect(result.ctx[:error]).to be_nil
    expect(result.ctx[:return_val]).to eq("Keep" => { "name" => "Keep" })
  end

  it "ignores a single commented line inside a Keyval.keyHash inner block" do
    code = <<~'JIL'
      pair = Keyval.keyHash("Outer", {
        # commented = Hash.keyval("a", "b")::Keyval
        kept = Hash.keyval("name", "Vitamins")::Keyval
      })::Keyval
      ret = Global.return(pair)::Hash
    JIL
    result = Jil::Executor.call(user, code)
    expect(result.ctx[:error]).to be_nil
    expect(result.ctx[:return_val]).to eq("Outer" => { "name" => "Vitamins" })
  end
end

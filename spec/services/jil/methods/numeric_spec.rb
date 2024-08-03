RSpec.describe Jil::Methods::Numeric do
  include ActiveJob::TestHelper
  let(:execute) { Jil::Executor.call(user, code, input_data) }
  let(:user) { User.create(id: 1, role: :admin, username: :admiin, password: :password, password_confirmation: :password) }
  let(:code) { "" }
  let(:input_data) { {} }
  let(:ctx) { execute.ctx }

  context "basic operator" do
    let(:code) {
      <<-JIL
        j7fce = Numeric.new(2)::Numeric
        j7fcb = j7fce.op("*", 5)::Numeric
      JIL
    }

    it "sets the new value" do
      expect_successful_jil
      expect(ctx[:vars]).to match_hash({
        j7fce: { class: :Numeric, value: 2 },
        j7fcb: { class: :Numeric, value: 10 },
      })
      expect(ctx[:output]).to eq([])
    end
  end

  context "set operator" do
    let(:code) {
      <<-JIL
        j7fce = Numeric.new(2)::Numeric
        j7fcb = j7fce.op!("*=", 5)::Numeric
      JIL
    }

    it "sets the new value to the old var" do
      expect_successful_jil
      expect(ctx[:vars]).to match_hash({
        j7fce: { class: :Numeric, value: 10 },
        j7fcb: { class: :Numeric, value: 10 },
      })
      expect(ctx[:output]).to eq([])
    end
  end
end

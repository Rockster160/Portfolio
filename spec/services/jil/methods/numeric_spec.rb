RSpec.describe Jil::Methods::Numeric do
  include ActiveJob::TestHelper
  let(:execute) { Jil::Executor.call(user, code, input_data) }
  let(:user) { User.me }
  let(:code) { "" }
  let(:input_data) { {} }
  let(:ctx) { execute.ctx }

  # [Numeric]::number
  #   #new(Any::Numeric)
  #   #pi(TAB "π" TAB)
  #   #e(TAB "e" TAB)
  #   #inf()
  #   #rand(Numeric:min Numeric:max Numeric?:figures)
  #   .round(Numeric(0))
  #   .floor
  #   .ceil
  #   .op(["+" "-" "*" "/" "%" "^log"] Numeric)
  #   .op!(["+=" "-=" "*=" "/=" "%="] Numeric)
  #   .abs
  #   .sqrt
  #   .squared
  #   .cubed
  #   .log(Numeric)
  #   .root(Numeric)
  #   .exp(Numeric)
  #   .zero?::Boolean
  #   .even?::Boolean
  #   .odd?::Boolean
  #   .prime?::Boolean
  #   .whole?::Boolean
  #   .positive?::Boolean
  #   .negative?::Boolean

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

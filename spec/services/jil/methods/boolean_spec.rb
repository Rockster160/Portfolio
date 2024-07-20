RSpec.describe Jil::Methods::Boolean do
  include ActiveJob::TestHelper
  let(:execute) { Jil::Executor.call(user, code, input_data) }
  let(:user) { User.create(id: 1, role: :admin, username: :admiin, password: :password, password_confirmation: :password) }
  let(:code) { "" }
  let(:input_data) { {} }
  let(:ctx) { execute.ctx }

  def expect_successful
    expect([ctx[:error_line], ctx[:error]].compact.join("\n")).to be_blank
  end

  context "new with casted vals" do
    let(:code) {
      <<-JIL
        j7fce = Numeric.new(1)::Numeric
        n7526 = String.new("1")::Numeric
        dfa1f = Boolean.eq(n7526, j7fce)::Boolean
      JIL
    }

    it "compares different types" do
      expect_successful
      expect(ctx[:vars]).to match_hash({
        j7fce: { class: :Numeric, value: 1 },
        n7526: { class: :Numeric, value: 1 },
        dfa1f: { class: :Boolean, value: true },
      })
      expect(ctx[:output]).to eq([])
    end
  end

  context "new with different vals" do
    let(:code) {
      <<-JIL
        j7fce = Numeric.new(1)::Numeric
        n7526 = String.new("1")::String
        dfa1f = Boolean.eq(n7526, j7fce)::Boolean
      JIL
    }

    it "compares different types" do
      expect_successful
      expect(ctx[:vars]).to match_hash({
        j7fce: { class: :Numeric, value: 1 },
        n7526: { class: :String, value: "1" },
        dfa1f: { class: :Boolean, value: false },
      })
      expect(ctx[:output]).to eq([])
    end
  end

  context "eq(Any '==' Any)" do
    let(:code) {
      <<-JIL
        j7fce = Numeric.new(1)::Numeric
        n7526 = String.new("1")::Numeric
        dfa1f = Boolean.eq(n7526, j7fce)::Boolean
      JIL
    }

    it "compares same types" do
      expect_successful
      expect(ctx[:vars]).to match_hash({
        j7fce: { class: :Numeric, value: 1 },
        n7526: { class: :Numeric, value: 1 },
        dfa1f: { class: :Boolean, value: true },
      })
      expect(ctx[:output]).to eq([])
    end
  end

  context "or(Any '||' Any)" do
    let(:code) {
      <<-JIL
        j7fce = Boolean.new(false)::Boolean
        n7526 = String.new("1")::Numeric
        dfa1f = Boolean.or(j7fce, n7526)::Boolean
      JIL
    }

    it "returns the value, not only bools" do
      expect_successful
      expect(ctx[:vars]).to match_hash({
        j7fce: { class: :Boolean, value: false },
        n7526: { class: :Numeric, value: 1 },
        dfa1f: { class: :Boolean, value: true },
      })
      expect(ctx[:output]).to eq([])
    end
  end

  context "and(Any '&&' Any)" do
    let(:code) {
      <<-JIL
        j7fce = Boolean.new(false)::Boolean
        n7526 = String.new("1")::Numeric
        dfa1f = Boolean.and(n7526, j7fce)::Boolean
      JIL
    }

    it "returns the value, not only bools" do
      expect_successful
      expect(ctx[:vars]).to match_hash({
        j7fce: { class: :Boolean, value: false },
        n7526: { class: :Numeric, value: 1 },
        dfa1f: { class: :Boolean, value: false },
      })
      expect(ctx[:output]).to eq([])
    end
  end

  context "not('NOT' Any)" do
    let(:code) {
      <<-JIL
        n7526 = String.new("1")::Numeric
        dfa1f = Boolean.not(n7526)::Boolean
      JIL
    }

    it "returns the value, not only bools" do
      expect_successful
      expect(ctx[:vars]).to match_hash({
        n7526: { class: :Numeric, value: 1 },
        dfa1f: { class: :Boolean, value: false },
      })
      expect(ctx[:output]).to eq([])
    end
  end

  context "compare(Any ['==' '!=' '>' '<' '>=' '<='] Any)" do
    let(:code) {
      <<-JIL
        j7fce = Numeric.new(5)::Numeric
        n7526 = Numeric.new(3)::Numeric
        dfa1f = Boolean.compare(n7526, ">", j7fce)::Boolean
      JIL
    }

    it "compares different types" do
      expect_successful
      expect(ctx[:vars]).to match_hash({
        j7fce: { class: :Numeric, value: 5 },
        n7526: { class: :Numeric, value: 3 },
        dfa1f: { class: :Boolean, value: false },
      })
      expect(ctx[:output]).to eq([])
    end
  end
end

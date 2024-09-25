RSpec.describe Jil::Methods::Global do
  include ActiveJob::TestHelper
  let(:execute) { ::Jil::Executor.call(user, code, input_data) }
  let(:user) { User.me }
  let(:code) { 'yf8a6 = Global.function("", {})::Function' }
  let(:input_data) { {} }
  let(:ctx) { execute.ctx }

  context "#function" do
    context "with no args" do
      let(:code) {
        <<-JIL
          yf8a6 = Global.function("", {
            a5699 = Global.print("Hello, World!")::String
            a5697 = Global.print("Goodbye, World!")::String
          })::Function
          re82f = yf8a6.call({})::Any
          c01ab = yf8a6.call({})::Any
        JIL
      }

      it "executes the function innards twice" do
        expect_successful_jil

        expect(ctx[:vars].keys).to match_array([:yf8a6, :a5699, :a5697, :re82f, :c01ab])
        expect(ctx.dig(:vars)).to match_hash({
          yf8a6: { class: :Function, value: {
            args: "",
            content: "a5699 = Global.print(\"Hello, World!\")::String\na5697 = Global.print(\"Goodbye, World!\")::String"
          } },
          a5699: { class: :String, value: "Hello, World!" },
          a5697: { class: :String, value: "Goodbye, World!" },
          re82f: { class: :Any, value: "Goodbye, World!" },
          c01ab: { class: :Any, value: "Goodbye, World!" },
        })
        expect(ctx[:output]).to eq(["Hello, World!", "Goodbye, World!", "Hello, World!", "Goodbye, World!"])
      end
    end

    context "with args" do
      let(:code) {
        <<-JIL
          yf8a6 = Global.function("name, time_of_day", {
            name = Keyword.Arg("name")::Any
            time = Keyword.Arg("time_of_day")::Any
            greeting = String.new("Good \#{time}, \#{name}!")::String
            j2594 = Keyword.FuncReturn(greeting)::Any
            fa4b8 = Global.print("This should not exist!")::String
          })::Function
          f1 = yf8a6.call({
            we83a = String.new("Rocco")::String
            k252c = String.new("morning")::String
          })::String
          f2 = yf8a6.call({
            w5b8c = String.new("Rocco")::String
            w59e0 = String.new("evening")::String
          })::String
          l2d7b = Global.print("\#{f1} - \#{f2}")::String
        JIL
      }

      it "allows using the variables within the function" do
        expect_successful_jil

        expect(ctx[:vars].keys).to match_array([:yf8a6, :we83a, :k252c, :name, :time, :greeting, :j2594, :f1, :w5b8c, :w59e0, :f2, :l2d7b])
        expect(ctx.dig(:vars)).to match_hash({
          yf8a6: {
            class: :Function,
            value: {
              args: "name, time_of_day",
              content: "name = Keyword.Arg(\"name\")::Any\ntime = Keyword.Arg(\"time_of_day\")::Any\ngreeting = String.new(\"Good \#{time}, \#{name}!\")::String\nj2594 = Keyword.FuncReturn(greeting)::Any\nfa4b8 = Global.print(\"This should not exist!\")::String",
            }
          },
          we83a: { class: :String, value: "Rocco" },
          k252c: { class: :String, value: "morning" },
          name: { class: :Any, value: "Rocco" },
          time: { class: :Any, value: "evening" },
          greeting: { class: :String, value: "Good evening, Rocco!" },
          j2594: { class: :Any, value: "Good evening, Rocco!" },
          f1: { class: :String, value: "Good morning, Rocco!" },
          w5b8c: { class: :String, value: "Rocco" },
          w59e0: { class: :String, value: "evening" },
          f2: { class: :String, value: "Good evening, Rocco!" },
          l2d7b: { class: :String, value: "Good morning, Rocco! - Good evening, Rocco!" },
        })
        expect(ctx[:output]).to eq(["Good morning, Rocco! - Good evening, Rocco!"])
      end
    end
  end
end

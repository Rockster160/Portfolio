RSpec.describe Jil::Methods::String do
  include ActiveJob::TestHelper
  let(:execute) { Jil::Executor.call(user, code, input_data) }
  let(:user) { User.me }
  let(:code) { "" }
  let(:input_data) { {} }
  let(:ctx) { execute.ctx }

  # [Text]::textarea
  #   #new(Text)::String
  # [String]::text
  #   #new(Any)
  #   .match(String)
  #   .scan(String)::Array
  #   .split(String?)::Array
  #   .format(["lower" "upper" "squish" "capital" "pascal" "title" "snake" "camel" "base64"])
  #   .replace(String "with" String)
  #   .add("+" String)
  #   .length()::Numeric

  describe "[Text]" do
    context "new" do
      let(:code) {
        <<-JIL
          na887 = Text.new(\"Hello, world!\")::Text
        JIL
      }

      it "sets the values of the variables inside the block and stores the print output" do
        expect_successful_jil
        expect(ctx[:vars]).to match_hash({
          na887: { class: :Text, value: "Hello, world!" },
        })
        expect(ctx[:output]).to eq([])
      end
    end
  end

  describe "[String]" do
    context "new" do
      let(:code) {
        <<-JIL
          na887 = String.new(\"Hello, world!\")::String
        JIL
      }

      it "stores the string" do
        expect_successful_jil
        expect(ctx[:vars]).to match_hash({
          na887: { class: :String, value: "Hello, world!" },
        })
        expect(ctx[:output]).to eq([])
      end
    end

    context "match" do
      let(:code) {
        <<-JIL
          na887 = String.new(\"Hello, world!\")::String
          na885 = na887.match(\"Hello\")::Boolean
        JIL
      }

      it "stores the string" do
        expect_successful_jil
        expect(ctx[:vars]).to match_hash({
          na887: { class: :String, value: "Hello, world!" },
          na885: { class: :Boolean, value: true },
        })
        expect(ctx[:output]).to eq([])
      end
    end

    context "scan" do
      let(:code) {
        <<-JIL
          na887 = String.new(\"Hello, world!\")::String
          na885 = na887.scan(\"Hello\")::Array
        JIL
      }

      it "stores the string" do
        expect_successful_jil
        expect(ctx[:vars]).to match_hash({
          na887: { class: :String, value: "Hello, world!" },
          na885: { class: :Array, value: ["Hello"] },
        })
        expect(ctx[:output]).to eq([])
      end
    end

    context "split" do
      let(:code) {
        <<-JIL
          na887 = String.new(\"Hello, world!\")::String
          na885 = na887.split(\"\")::Array
        JIL
      }

      it "split" do
        expect_successful_jil
        expect(ctx[:vars]).to match_hash({
          na887: { class: :String, value: "Hello, world!" },
          na885: { class: :Array, value: "Hello, world!".split("") },
        })
        expect(ctx[:output]).to eq([])
      end
    end

    context "format" do
      let(:start_string) { "hello, World!" }
      [
        [:lower,   "hello, world!"],
        [:upper,   "HELLO, WORLD!"],
        [:squish,  "hello, World!", " hello, World!      "],
        [:capital, "Hello, world!"],
        [:pascal,  "HelloWorld"],
        [:title,   "Hello, World!"],
        [:snake,   "hello_world"],
        [:camel,   "helloWorld"],
        [:base64,  "aGVsbG8sIFdvcmxkIQ=="],
      ].each do |formatter, goal, from|
        context formatter.to_s do
          let(:code) {
            <<-JIL
              na887 = String.new(\"#{from || start_string}\")::String
              na885 = na887.format(\"#{formatter}\")::String
            JIL
          }

          it "format" do
            expect_successful_jil
            expect(ctx[:vars]).to match_hash({
              na887: { class: :String, value: from || start_string },
              na885: { class: :String, value: goal },
            })
            expect(ctx[:output]).to eq([])
          end
        end
      end
    end

    context "replace" do
      context "replace with string" do
        let(:code) {
          <<-JIL
            na887 = String.new(\"Hello, world!\")::String
            na885 = na887.replace(\"Hello\", \"Goodbye\")::String
          JIL
        }

        it "works" do
          expect_successful_jil
          expect(ctx[:vars]).to match_hash({
            na887: { class: :String, value: "Hello, world!" },
            na885: { class: :String, value: "Goodbye, world!" },
          })
          expect(ctx[:output]).to eq([])
        end
      end

      context "replace with regex" do
        let(:code) {
          <<-JIL
            na887 = String.new(\"Hello, world!\")::String
            na885 = na887.replace(\"/Hello,?\\s* /\", \"\")::String
          JIL
        }

        it "works" do
          expect_successful_jil
          expect(ctx[:vars]).to match_hash({
            na887: { class: :String, value: "Hello, world!" },
            na885: { class: :String, value: "world!" },
          })
          expect(ctx[:output]).to eq([])
        end
      end
    end

    context "add" do
      let(:code) {
        <<-JIL
          na887 = String.new(\"Hello, world!\")::String
          na885 = na887.add(\" Goodbye, world!\")::String
        JIL
      }

      it "add" do
        expect_successful_jil
        expect(ctx[:vars]).to match_hash({
          na887: { class: :String, value: "Hello, world!" },
          na885: { class: :String, value: "Hello, world! Goodbye, world!" },
        })
        expect(ctx[:output]).to eq([])
      end
    end

    context "length" do
      let(:code) {
        <<-JIL
          na887 = String.new(\"Hello, world!\")::String
          na885 = na887.length()::Numeric
        JIL
      }

      it "length" do
        expect_successful_jil
        expect(ctx[:vars]).to match_hash({
          na887: { class: :String, value: "Hello, world!" },
          na885: { class: :Numeric, value: 13 },
        })
        expect(ctx[:output]).to eq([])
      end
    end
  end
end

RSpec.describe Jil::Executor do
  include ActiveJob::TestHelper
  let(:execute) { described_class.call(user, code, input_data) }
  let(:user) { User.create(id: 1, role: :admin, username: :admiin, password: :password, password_confirmation: :password) }
  let(:code) { "" }
  let(:input_data) { {} }
  let(:ctx) { execute.ctx }

  def expect_successful
    # expect(ctx[:error_line]).to be_blank
    expect(ctx[:error]).to be_blank
  end

  describe "[Global]" do
    context "if" do
      # let(:code) { jil_fixture(:garage_cell) }
      let(:code) {
        <<-JIL
          z71ef = Global.if({
            na887 = Boolean.new(true)::Boolean
          }, {
            tbd36 = Global.print("Success")::String
          }, {
            f6187 = Global.print("Failure")::String
          })::Any
        JIL
      }

      it "sets the values of the variables inside the block and stores the print output" do
        expect_successful
        expect(ctx[:vars]).to match_hash({
          na887: { class: :Boolean, value: true },
          tbd36: { class: :String,  value: "Success" },
          z71ef: { class: :Any,     value: "Success" },
        })
        expect(ctx[:output]).to eq(["Success"])
      end
    end
  end

  describe "[Boolean]" do
    context "if" do
      # let(:code) { jil_fixture(:garage_cell) }
      let(:code) {
        <<-JIL
          na887 = Boolean.new(true)::Boolean
          na882 = Boolean.new(false)::Boolean
          tbd36 = Global.print("\#{na882}")::String
          # abc123 = Global.print("\#{na882}")::String # Doesn't show up in vars
        JIL
      }

      it "sets the values of the variables inside the block and stores the print output" do
        expect_successful
        expect(ctx[:vars]).to match_hash({
          na887: { class: :Boolean, value: true },
          na882: { class: :Boolean, value: false },
          tbd36: { class: :String,  value: "false" },
        })
        expect(ctx[:output]).to eq(["false"])
      end
    end
  end

  describe "[Text]" do
    context "new" do
      let(:code) {
        <<-JIL
          na887 = Text.new(\"Hello, world!\")::Text
        JIL
      }

      it "sets the values of the variables inside the block and stores the print output" do
        expect_successful
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
        expect_successful
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
        expect_successful
        expect(ctx[:vars]).to match_hash({
          na887: { class: :String, value: "Hello, world!" },
          na885: { class: :Boolean, value: true },
        })
        expect(ctx[:output]).to eq([])
      end
    end
  end
end
# [ ] [Global]
# [ ] [Keyval]
# [√] [Text]
# [ ] [String]
# [ ] [Numeric]
# [√] [Boolean]
# [ ] [Duration]
# [ ] [Date]
# [ ] [Hash]
# [ ] [Array]
# [ ] [List]
# [ ] [ListItem]
# [ ] [ActionEvent]
# [ ] [Prompt]
# [ ] [PromptQuestion]
# [ ] [Task]
# [ ] [Email]

# [Global]
#   // #qloop(content(["Break" "Next" "Index"::Numeric]))::Numeric
#   // #switch(Any::Boolean)
#   // #thing(TAB "π" TAB)
#   // #test(String?("Default Value"):"Bigger Placeholder" "and" Numeric(2))
#   #input_data::Hash
#   #return(Any?)
#   #if("IF" content "DO" content "ELSE" content)::Any
#   #get(String)::Any // Variable reference
#   #set(String "=" Any)::Any
#   #get_cache(String)::Any // Could Cache.get be a non-object Class? Doesn't show up in return-types, but is still a class for organization
#   #set_cache(String "=" Any)::Any
#   #exit
#   #print(Text)::String
#   #comment(Text)::None
#   #command(String)::String
#   #request("Method" String BR "URL" String BR "Params" Hash BR "Headers" Hash)::Hash
#   #broadcast_websocket("Channel" TAB String BR "Data" TAB Hash)::Numeric
#   #trigger(String Hash)::Numeric
#   #dowhile(content(["Break" "Next" "Index"::Numeric]))::Numeric
#   #loop(content(["Break" "Next" "Index"::Numeric]))::Numeric
#   #times(Numeric content(["Break" "Next" "Index"::Numeric]))::Numeric
#   #eval(Text) # Should return the value given by a "return" that's called inside
# [Keyval]
#   #new(String ": " Any)
# [Text]::textarea
#   #new(Text)::String
# [String]::text
#   #new(Any)
#   .match(String)
#   .scan(String)::Array
#   .split(String?)::Array
#   .format(["lower" "upper" "squish" "capital" "pascal" "title" "snake" "camel" "base64"])
#   .replace(String)
#   .add("+" String)
#   .length()::Numeric
# [Numeric]::number
#   #new(Any::Numeric)
#   #pi(TAB "π" TAB)
#   #e(TAB "e" TAB)
#   #inf()
#   #rand(Numeric:min Numeric:max Numeric?:figures)
#   .round(Numeric(0))
#   .floor
#   .ceil
#   .op(["+" "-" "*" "/" "^log"] Numeric)
#   .abs
#   .sqrt
#   .squared
#   .cubed
#   .log(Numeric)
#   .root(Numeric)
#   .exp(Numeric)
#   .zero?
#   .even?
#   .odd?
#   .prime?
#   .whole?
#   .positive?
#   .negative?
# [Boolean]::checkbox
#   #new(Any::Boolean)
#   #eq(Any "==" Any)
#   #or(Any "||" Any)
#   #and(Any "&&" Any)
#   #not("NOT" Any)
#   #compare(Any ["==" "!=" ">" "<" ">=" "<="] Any)
# [Duration]
#   #new(Numeric ["seconds" "minutes" "hours" "days" "weeks" "months" "years"])
#   .add(Duration)
#   .subtract(Duration)
# [Date]::datetime-local
#   #new(Numeric:year Numeric:month Numeric:day Numeric:hour Numeric:min Numeric:sec)
#   #now
#   .piece(["second" "minute" "hour" "day" "week" "month" "year"])::Numeric
#   .adjust(["+", "-"], Duration|Numeric)
#   .round("TO" ["beginning" "end"] "OF" ["second" "minute" "hour" "day" "week" "month" "year"])
#   .format(String)::String
# [Hash]
#   #new(content(Keyval [Keyval.new]))
#   #keyval(String Any)::Keyval
#   .length::Numeric
#   .dig(content(String [String.new]))::Any
#   .merge(Hash)
#   .keys::Array
#   .get(String)::Any
#   .set(String "=" Any)
#   .del(String)
#   .each(content(["Key"::String "Value"::Any "Index"::Numeric)])
#   .map(content(["Key"::String "Value"::Any "Index"::Numeric)])::Array
#   .any?(content(["Key"::String "Value"::Any "Index"::Numeric)])::Boolean
#   .none?(content(["Key"::String "Value"::Any "Index"::Numeric)])::Boolean
#   .all?(content(["Key"::String "Value"::Any "Index"::Numeric)])::Boolean
# [Array]
#   #new(content)
#   #from_length(Numeric)
#   .length::Numeric
#   .merge
#   .get(Numeric)::Any
#   .set(Numeric "=" Any)
#   .del(Numeric)
#   .pop!::Any
#   .push!(Any)
#   .shift!::Any
#   .unshift!(Any)
#   .each(content(["Object"::Any "Index"::Numeric)])
#   .map(content(["Object"::Any "Index"::Numeric)])
#   .find(content(["Object"::Any "Index"::Numeric)])::Any
#   .any?(content(["Object"::Any "Index"::Numeric)])::Boolean
#   .none?(content(["Object"::Any "Index"::Numeric)])::Boolean
#   .all?(content(["Object"::Any "Index"::Numeric)])::Boolean
#   .sort_by(content(["Object"::Any "Index"::Numeric)])
#   .sort_by!(content(["Object"::Any "Index"::Numeric)])
#   .sort(["Ascending" "Descending" "Reverse" "Random"])
#   .sort!(["Ascending" "Descending" "Reverse" "Random"])
#   .sample::Any
#   .min::Any
#   .max::Any
#   .sum::Any
#   .join(String)::String
# [List]
#   #find(String|Numeric)
#   #search(String)::Array
#   #create(String)
#   .name::String
#   .update(String?:"Name")::Boolean
#   .destroy::Boolean
#   .add(String)::Boolean
#   .remove(String)::Boolean
#   .items::Array
# [ListItem]
#   #find(String|Numeric)
#   #search(String)::Array # All items belonging to user through user lists
#   .update(String?:"Name" String?:"Notes" Hash?:"Data")::Boolean
#   .name::String
#   .notes::String
#   .data::Hash
#   .destroy::Boolean
# [ActionEvent]
#   #find(String|Numeric)
#   #search(String "limit" Numeric(50) "since" Date? "order" ["ASC" "DESC"])::Array
#   #add("Name" TAB String BR "Notes" TAB String? BR "Data" TAB Hash? BR "Date" TAB Date?)
#   .id::Numeric
#   .name::Numeric
#   .notes::Numeric
#   .data::Hash
#   .date::Date
#   .update("Name" TAB String BR "Notes" TAB String? BR "Data" TAB Hash? BR "Date" TAB Date?)::Boolean
#   .destroy::Boolean
# [Prompt]
#   #find(String|Numeric)
#   #all("complete?" Boolean(false))::Array
#   #create("Title" TAB String BR "Params" TAB Hash? BR "Data" TAB Hash? BR "Questions" content(PromptQuestion))
#   .update("Title" TAB String BR "Params" TAB Hash? BR "Data" TAB Hash? BR "Questions" content(PromptQuestion))::Boolean
#   .destroy::Boolean
# [PromptQuestion]
#   #text(String:"Question Text" BR "Default" String)
#   #checkbox(String:"Question Text")
#   #choices(String:"Question Text" content(String))
#   #scale(String:"Question Text" BR Numeric:"Min" Numeric:"Max")
# [Task]
#   #find(String|Numeric)
#   #search(String)::Array
#   .enable(Boolean(true))::Boolean
#   .run(Date?)
# [Email]
#   #find(String|Numeric)
#   #search(String)::Array
#   #create("To" TAB String BR "Subject" TAB String BR Text)
#   .to::String
#   .from::String
#   .body::String
#   .text::String
#   .html::String
#   .archive(Boolean(true))::Boolean

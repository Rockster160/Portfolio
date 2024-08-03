RSpec.describe Jil::Executor do
  include ActiveJob::TestHelper
  let(:execute) { described_class.call(user, code, input_data) }
  let(:user) { User.create(id: 1, role: :admin, username: :admiin, password: :password, password_confirmation: :password) }
  let(:code) { "" }
  let(:input_data) { {} }
  let(:ctx) { execute.ctx }

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
        expect_successful_jil
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
        expect_successful_jil
        expect(ctx[:vars]).to match_hash({
          na887: { class: :Boolean, value: true },
          na882: { class: :Boolean, value: false },
          tbd36: { class: :String,  value: "false" },
        })
        expect(ctx[:output]).to eq(["false"])
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
#   #set!(String "=" Any)::Any
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

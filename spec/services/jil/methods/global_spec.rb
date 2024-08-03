RSpec.describe Jil::Methods::Global do
  include ActiveJob::TestHelper
  let(:execute) { ::Jil::Executor.call(user, code, input_data) }
  let(:user) { User.create(id: 1, role: :admin, username: :admiin, password: :password, password_confirmation: :password) }
  let(:code) {
    <<-JIL
      r5ee3 = Array.new({
        rb9ed = String.new("Hello, World!")::String
        ydfcd = Boolean.new(false)::Boolean
        xfaed = Numeric.new(47)::Numeric
      })::Array
    JIL
  }
  let(:input_data) { {} }
  let(:ctx) { execute.ctx }

  # Specifically need to test loops, cache, and variables

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
  #   #set_cache!(String "=" Any)::Any
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

  # context "#new" do
  #   it "stores the items" do
  #     expect_successful_jil
  #     expect(ctx.dig(:vars)).to match_hash({
  #       rb9ed: { class: :String, value: "Hello, World!" },
  #       ydfcd: { class: :Boolean, value: false },
  #       xfaed: { class: :Numeric, value: 47 },
  #       r5ee3: { class: :Array, value: ["Hello, World!", false, 47] },
  #     })
  #     expect(ctx[:output]).to eq([])
  #   end
  # end
  #
  # context "#from_length" do
  #   let(:code) { "r5ee3 = Array.from_length(5)::Array" }
  #
  #   it "creates an array of nil of the desired length" do
  #     expect_successful_jil
  #     expect(ctx.dig(:vars)).to match_hash({
  #       r5ee3: { class: :Array, value: [nil, nil, nil, nil, nil] },
  #     })
  #     expect(ctx[:output]).to eq([])
  #   end
  # end
  #
  # context ".length" do
  #   before do
  #     code << "r817a = r5ee3.length()::Numeric"
  #   end
  #
  #   it "returns the number of items in the hash" do
  #     expect_successful_jil
  #     expect(ctx.dig(:vars)).to match_hash({
  #       rb9ed: { class: :String, value: "Hello, World!" },
  #       ydfcd: { class: :Boolean, value: false },
  #       xfaed: { class: :Numeric, value: 47 },
  #       r5ee3: { class: :Array, value: ["Hello, World!", false, 47] },
  #       r817a: { class: :Numeric, value: 3 },
  #     })
  #     expect(ctx[:output]).to eq([])
  #   end
  # end
end

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

  # [Global]
  #   #input_data::Hash
  #   #return(Any?)
  #   #if("IF" content "DO" content "ELSE" content)::Any
  #   #get(String)::Any // Variable reference
  #   #set!(String "=" Any)::Any
  #   #get_cache(String:"Cache Key" Any)::Any
  #   #dig_cache(String:"Cache Key" content(Keyval [Keyval.new]))::Any
  #   #set_cache(String:"Cache Key" Any "=" Any)::Any
  #   #print(Text)::String
  #   #comment(Text)::None
  #   #command(String)::String
  #   #request("Method" String BR "URL" String BR "Params" Hash BR "Headers" Hash)::Hash
  #   #broadcast_websocket("Channel" TAB String BR "Data" TAB Hash)::Numeric
  #   #trigger(String Hash)::Numeric
  #   #dowhile(content(["Break"::Any "Next"::Any "Index"::Numeric]))::Any
  #   #loop(content(["Break"::Any "Next"::Any "Index"::Numeric]))::Any
  #   #times(Numeric content(["Break"::Any "Next"::Any "Index"::Numeric]))::Numeric

  # times

  context "#loop, Next, Break, Index, Return" do
    #dowhile(enum_content)::Numeric
    let(:code) {
      <<-'JIL'
        outer_counter = Numeric.new(0)::Numeric
        inner_counter = Numeric.new(0)::Numeric
        fc4d9 = Global.loop({
          oidx = Global.Index()::Numeric
          mb88e = Global.print("Outer #{oidx}")::String
          nc692 = outer_counter.op!("+=", 1)::Numeric
          g2c6d = Global.loop({
            iidx = Global.Index()::Numeric
            e1b14 = inner_counter.op!("+=", 1)::Numeric
            uc906 = Global.if({
              v26d7 = iidx.even?()::Boolean
            }, {
              l9380 = Global.Next("")::Any
            }, {})::Any
            ub716 = Global.print("Post Next #{iidx}")::String
            j52aa = Global.if({
              q83c5 = Boolean.eq("#{iidx}", "3")::Boolean
            }, {
              e03a2 = Global.Break("")::Any
            }, {})::Any
            ub717 = Global.print("Inner #{iidx}")::String
          })::Numeric
          pfe1b = Global.set!("inner_counter", "0")::Numeric
          i5ad2 = Global.if({
            q22df = Boolean.eq("#{outer_counter}", "3")::Boolean
          }, {
            m690b = Global.Break("")::Any
          }, {})::Any
        })::Numeric
      JIL
    }

    it "loops through, respecting breaks and nexts and return" do
      # _scripts/jil/demo_script.rb
      expect_successful_jil
      expect(ctx.dig(:vars, :outer_counter, :value)).to eq(3)
      expect(ctx.dig(:vars, :inner_counter, :value)).to eq("0")
      expect(ctx[:output]).to eq([
        "Outer 0",
        "Post Next 1",
        "Inner 1",
        "Post Next 3",
        "Outer 1",
        "Post Next 1",
        "Inner 1",
        "Post Next 3",
        "Outer 2",
        "Post Next 1",
        "Inner 1",
        "Post Next 3"
      ])
    end
  end

  context "cache and variables" do
    let(:code) {
      <<-JIL
        s1e23 = Global.set!("abc", "123")::Numeric
        cf84b = Global.get_cache("jil", "answer")::Numeric
        w9886 = cf84b.op!("+=", 5)::Numeric
        ucf39 = s1e23.op!("+=", 5)::Numeric
        je119 = Global.get_cache("jil", "answer")::Numeric
        h43d4 = Global.get("abc")::Numeric
        ga973 = Global.set_cache("jil", "answer", "4321")::Numeric
        d6c8b = ga973.op!("+=", 5)::Numeric
        b2a68 = Global.get_cache("jil", "answer")::Numeric
        q5fa3 = b2a68.op!("+=", 5)::Numeric
        t0f98 = Global.get_cache("jil", "answer")::Numeric
        daaab = Global.get("abc")::Numeric
      JIL
    }

    before do
      # Maybe we should nest these values in a different cache reserved for tasks?
      user.caches.dig_set(:jil, :answer, 321)
    end

    it "modifies variables inline, but does not change the external cache values" do
      expect_successful_jil
      expect(ctx[:vars]).to match_hash({
        abc: { class: :Any, value: "123" },
        s1e23: { class: :Numeric, value: 128 },
        cf84b: { class: :Numeric, value: 326 },
        w9886: { class: :Numeric, value: 326 },
        ucf39: { class: :Numeric, value: 128 },
        je119: { class: :Numeric, value: 321 }, # Unchanged
        h43d4: { class: :Numeric, value: 123 }, # Unchanged
        ga973: { class: :Numeric, value: 4326 },
        d6c8b: { class: :Numeric, value: 4326 },
        b2a68: { class: :Numeric, value: 4326 },
        q5fa3: { class: :Numeric, value: 4326 },
        t0f98: { class: :Numeric, value: 4321 }, # Unchanged
        daaab: { class: :Numeric, value: 123 }, # Unchanged
      })
      expect(ctx[:output]).to eq([])
    end
  end

  context "#request" do # Working, just commented out to avoid needless requests
    # let(:code) { 'ee984 = Global.request("GET", "https://a.4cdn.org/boards.json", "", "")::Hash' }
    #
    # it "hits an endpoint and returns the data" do
    #   expect_successful_jil
    #
    #   data = ctx.dig(:vars, :ee984)
    #   expect(data[:class]).to eq(:Hash)
    #   expect(data[:value].keys).to match_array([:code, :body, :headers])
    #   expect(data.dig(:value, :body).class).to eq(::Hash)
    # end
  end

  context "#command" do
    let(:code) { 'ee984 = Global.command("Add whatever")::String' }

    before do
      user.lists.create(name: "TODO")
    end

    it "commands Jarvis to do the thing" do
      expect_successful_jil

      expect(ctx[:vars]).to match_hash({
        ee984: { class: :String, value: "TODO:\n - whatever" }
      })
    end
  end

  context "#broadcast_websocket" do
    let(:code) {
      <<-JIL
        v305d = Hash.new({
          i785d = Keyval.new("action", "open")::Keyval
        })::Hash
        ldfd0 = Global.broadcast_websocket("garage", v305d)::Numeric
      JIL
    }

    it "commands Jarvis to do the thing" do
      expect_successful_jil

      expect(ctx[:vars]).to match_hash({
        i785d: { class: :Keyval,  value: {"action"=>"open"} },
        v305d: { class: :Hash,    value: {"action"=>"open"} },
        ldfd0: { class: :Numeric, value: 0 },
      })
    end
  end

  context "#trigger" do
    let(:task_code) {
      <<-JIL
        r5ee3 = Array.new({
          rb9ed = String.new("Hello, World!")::String
          ydfcd = Boolean.new(false)::Boolean
          xfaed = Numeric.new(47)::Numeric
        })::Array
      JIL
    }
    let!(:task) {
      ::JilTask.create(listener: "magic:listener", user: user, code: task_code)
    }
    let(:code) {
      <<-JIL
        e2e54 = Hash.new({
          qe8be = Keyval.keyHash("nest", {
            ne65c = Keyval.keyHash("data", {
              d8e4a = Keyval.new("foo", "listener")::Keyval
            })::Keyval
          })::Keyval
        })::Hash
        z54c9 = Global.trigger("magic", e2e54)::Numeric
      JIL
    }

    it "triggers the relevant tasks" do
      expect_successful_jil

      expect(ctx[:vars]).to match_hash({
        d8e4a: { class: :Keyval,  value: {"foo": "listener"} },
        ne65c: { class: :Keyval,  value: {"data": {"foo": "listener"}} },
        qe8be: { class: :Keyval,  value: {"nest": {"data": {"foo": "listener"}}} },
        e2e54: { class: :Hash,    value: {"nest": {"data": {"foo": "listener"}}} },
        z54c9: { class: :Numeric, value: 1 },
      })
      expect(::JilExecution.count).to eq(2)
    end
  end
end

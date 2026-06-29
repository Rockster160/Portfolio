RSpec.describe Jil::Methods::Global do
  include ActiveJob::TestHelper

  let(:execute) { ::Jil::Executor.call(user, code, input_data) }
  let(:user) { User.me }
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

  describe "#loop, Next, Break, Index, Return" do
    # dowhile(enum_content)::Numeric
    let(:code) {
      <<-'JIL'
        outer_counter = Numeric.new(0)::Numeric
        inner_counter = Numeric.new(0)::Numeric
        fc4d9 = Global.loop({
          oidx = Keyword.Index()::Numeric
          mb88e = Global.print("Outer #{oidx}")::String
          nc692 = outer_counter.op!("+=", 1)::Numeric
          g2c6d = Global.loop({
            iidx = Keyword.Index()::Numeric
            e1b14 = inner_counter.op!("+=", 1)::Numeric
            uc906 = Global.if({
              v26d7 = iidx.even?()::Boolean
            }, {
              l9380 = Keyword.Next("")::Any
            }, {})::Any
            ub716 = Global.print("Post Next #{iidx}")::String
            j52aa = Global.if({
              q83c5 = Boolean.eq("#{iidx}", "3")::Boolean
            }, {
              e03a2 = Keyword.Break("")::Any
            }, {})::Any
            ub717 = Global.print("Inner #{iidx}")::String
          })::Numeric
          pfe1b = Global.set!("inner_counter", "0")::Numeric
          i5ad2 = Global.if({
            q22df = Boolean.eq("#{outer_counter}", "3")::Boolean
          }, {
            m690b = Keyword.Break("")::Any
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
        "Post Next 3",
      ])
    end
  end

  describe "#case" do
    let(:code) {
      <<-'JIL'
        val = String.new("banana")::String
        result = Global.case(val, {
          a1234 = Keyword.When("apple", {
            b1234 = Global.print("it's an apple")::String
          })::Any
          c1234 = Keyword.When("banana", {
            d1234 = Global.print("it's a banana")::String
          })::Any
          e1234 = Keyword.When("cherry", {
            f1234 = Global.print("it's a cherry")::String
          })::Any
        })::Any
      JIL
    }

    it "matches the correct branch" do
      expect_successful_jil
      expect(ctx[:output]).to eq(["it's a banana"])
      expect(ctx.dig(:vars, :result, :value)).to eq("it's a banana")
    end
  end

  describe "#case with no match" do
    let(:code) {
      <<-'JIL'
        val = String.new("grape")::String
        result = Global.case(val, {
          a1234 = Keyword.When("apple", {
            b1234 = Global.print("it's an apple")::String
          })::Any
          c1234 = Keyword.When("banana", {
            d1234 = Global.print("it's a banana")::String
          })::Any
        })::Any
      JIL
    }

    it "returns nil when no branch matches" do
      expect_successful_jil
      expect(ctx[:output]).to eq([])
      expect(ctx.dig(:vars, :result, :value)).to be_nil
    end
  end

  describe "#case with else" do
    let(:code) {
      <<-'JIL'
        val = String.new("grape")::String
        result = Global.case(val, {
          a1234 = Keyword.When("apple", {
            b1234 = Global.print("it's an apple")::String
          })::Any
          c1234 = Keyword.When("else", {
            d1234 = Global.print("no match")::String
          })::Any
        })::Any
      JIL
    }

    it "falls through to else" do
      expect_successful_jil
      expect(ctx[:output]).to eq(["no match"])
    end
  end

  describe "#case with regex" do
    let(:code) {
      <<-'JIL'
        val = String.new("backyard")::String
        result = Global.case(val, {
          a1234 = Keyword.When("/front/", {
            b1234 = Global.print("front match")::String
          })::Any
          c1234 = Keyword.When("/back/", {
            d1234 = Global.print("back match")::String
          })::Any
          e1234 = Keyword.When("else", {
            f1234 = Global.print("no match")::String
          })::Any
        })::Any
      JIL
    }

    it "matches using regex" do
      expect_successful_jil
      expect(ctx[:output]).to eq(["back match"])
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
        abc:   { class: :Any, value: "123" },
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

  describe "#command" do
    let(:code) { 'ee984 = Global.command("Add whatever")::String' }

    before do
      user.lists.create(name: "TODO")
    end

    it "commands Jarvis to do the thing" do
      expect_successful_jil

      expect(ctx[:vars]).to match_hash({
        ee984: { class: :String, value: "TODO:\n - whatever" },
      })
    end
  end

  describe "#trigger command" do
    let(:code) {
      <<-JIL
        k16d3 = Global.trigger("command", "", {
          h59a1 = Keyval.new("words", "add it")::Keyval
        })::Schedule
      JIL
    }

    before do
      user.lists.create(name: "TODO")
    end

    it "commands Jarvis to do the thing" do
      expect_successful_jil

      expect(user.lists.first.list_items.first.name).to eq("it")
    end
  end

  describe "#broadcast_websocket" do
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
        i785d: { class: :Keyval,  value: { "action"=>"open" } },
        v305d: { class: :Hash,    value: { "action"=>"open" } },
        ldfd0: { class: :Numeric, value: 0 },
      })
    end
  end

  describe "#remove_triggers_by_scope" do
    let(:source_item) {
      agenda = create(:agenda, user: user)
      allow(::AddressBook).to receive(:non_travelable?).and_return(true)
      agenda.agenda_items.create!(
        name: "TMS",
        kind: :event,
        start_at: 2.days.from_now.beginning_of_hour,
        end_at:   2.days.from_now.beginning_of_hour + 1.hour,
        location: "Office",
      )
    }

    let(:input_data) { source_item }
    let(:code) {
      <<-JIL
        evt = Global.input_data()::AgendaItem
        removed = Global.remove_triggers_by_scope(evt, "agenda-travel-refresh")::Numeric
      JIL
    }

    it "destroys every scheduled_trigger with matching (source, scope), regardless of name" do
      user.scheduled_triggers.create!(
        source_item: source_item, name: "🔄 Pick up red wine",
        trigger: "agenda-travel-refresh", execute_at: 1.hour.from_now, offset_seconds: -600,
      )
      user.scheduled_triggers.create!(
        source_item: source_item, name: "🔄 Pick up red wine & milanos",
        trigger: "agenda-travel-refresh", execute_at: 1.hour.from_now, offset_seconds: -600,
      )
      user.scheduled_triggers.create!(
        source_item: source_item, name: "🏠 Drive home",
        trigger: "agenda-travel-nav-home", execute_at: 2.hours.from_now, offset_seconds: -600,
      )

      expect_successful_jil

      expect(ctx[:vars][:removed][:value]).to eq(2)
      expect(user.scheduled_triggers.where(source_item_id: source_item.id, trigger: "agenda-travel-refresh").count).to eq(0)
      # Untouched: different scope.
      expect(user.scheduled_triggers.where(source_item_id: source_item.id, trigger: "agenda-travel-nav-home").count).to eq(1)
    end

    it "returns 0 when nothing matches" do
      expect_successful_jil
      expect(ctx[:vars][:removed][:value]).to eq(0)
    end

    context "with except_name" do
      let(:code) {
        <<-JIL
          evt = Global.input_data()::AgendaItem
          keep = String.new("🔄 Pick up red wine & milanos")::String
          removed = Global.remove_triggers_by_scope(evt, "agenda-travel-refresh", keep)::Numeric
        JIL
      }

      it "keeps the matching row, removes the rest" do
        user.scheduled_triggers.create!(
          source_item: source_item, name: "🔄 Pick up red wine",
          trigger: "agenda-travel-refresh", execute_at: 1.hour.from_now, offset_seconds: -600,
        )
        kept = user.scheduled_triggers.create!(
          source_item: source_item, name: "🔄 Pick up red wine & milanos",
          trigger: "agenda-travel-refresh", execute_at: 1.hour.from_now, offset_seconds: -600,
        )

        expect_successful_jil

        expect(ctx[:vars][:removed][:value]).to eq(1)
        expect(user.scheduled_triggers.where(source_item_id: source_item.id, trigger: "agenda-travel-refresh").pluck(:id)).to eq([kept.id])
      end
    end
  end

  describe "#trigger" do
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
      ::Task.create(listener: "magic:listener", user: user, code: task_code)
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
        z54c9 = Global.triggerNow("magic", e2e54)::Numeric
      JIL
    }

    it "triggers the relevant tasks" do
      expect_successful_jil

      expect(ctx[:vars]).to match_hash({
        d8e4a: { class: :Keyval,  value: { foo: "listener" } },
        ne65c: { class: :Keyval,  value: { data: { foo: "listener" } } },
        qe8be: { class: :Keyval,  value: { nest: { data: { foo: "listener" } } } },
        e2e54: { class: :Hash,    value: { nest: { data: { foo: "listener" } } } },
        z54c9: { class: :Numeric, value: 1 },
      })
      expect(::Execution.count).to eq(2)
    end
  end

  describe "#ping, #say, #textMe, #remind" do
    # All four bypass Jarvis.command (and thus the :tell listener bus) and route
    # directly to the appropriate channel via Jarvis.broadcast.
    it "ping routes to WebPushNotifications without firing :tell" do
      expect(::Jarvis).to receive(:broadcast).with(user, "hello there", :ping)
      expect(::Jil).not_to receive(:trigger).with(anything, :tell, anything, anything)
      ::Jil::Executor.call(user, <<~'JIL')
        r = Global.ping("hello there")::String
      JIL
    end

    it "say routes to JarvisChannel websocket" do
      expect(::Jarvis).to receive(:broadcast).with(user, "spoken text", :ws)
      ::Jil::Executor.call(user, <<~'JIL')
        r = Global.say("spoken text")::String
      JIL
    end

    it "textMe routes to SmsWorker" do
      expect(::Jarvis).to receive(:broadcast).with(user, "sms text", :sms)
      ::Jil::Executor.call(user, <<~'JIL')
        r = Global.textMe("sms text")::String
      JIL
    end

    it "remind pings AND adds to default list" do
      list = user.default_list || user.lists.create!(name: "TODO")
      allow(user).to receive(:default_list).and_return(list)
      expect(::Jarvis).to receive(:broadcast).with(user, "buy milk", :ping)
      expect(list).to receive(:add_items).with(name: "buy milk")
      ::Jil::Executor.call(user, <<~'JIL')
        r = Global.remind("buy milk")::String
      JIL
    end

    it "ping with a future date schedules instead of broadcasting" do
      expect(::Jarvis).not_to receive(:broadcast)
      expect(::Jil::Schedule).to receive(:add_schedule).with(
        user, kind_of(::Time), :broadcast,
        a_hash_including(text: "later text", channel: :ping),
        hash_including(auth: :trigger),
      )
      ::Jil::Executor.call(user, <<~'JIL')
        at = Date.from_now(2, "minutes")::Date
        r = Global.ping("later text", at)::String
      JIL
    end

    it "remind with a future date schedules with add_to_list=true" do
      expect(::Jarvis).not_to receive(:broadcast)
      expect(::Jil::Schedule).to receive(:add_schedule).with(
        user, kind_of(::Time), :broadcast,
        a_hash_including(text: "later remind", channel: :ping, add_to_list: true),
        hash_including(auth: :trigger),
      )
      ::Jil::Executor.call(user, <<~'JIL')
        at = Date.from_now(5, "minutes")::Date
        r = Global.remind("later remind", at)::String
      JIL
    end

    it ":broadcast scheduled trigger invokes Jarvis.broadcast" do
      expect(::Jarvis).to receive(:broadcast).with(user, "scheduled hi", :ping)
      ::Jil::Executor.trigger(user, :broadcast, { text: "scheduled hi", channel: :ping })
    end

    it ":broadcast with add_to_list also adds to default list" do
      list = user.default_list || user.lists.create!(name: "TODO")
      allow(user).to receive(:default_list).and_return(list)
      expect(::Jarvis).to receive(:broadcast).with(user, "scheduled remind", :ping)
      expect(list).to receive(:add_items).with(name: "scheduled remind")
      ::Jil::Executor.trigger(
        user, :broadcast,
        { text: "scheduled remind", channel: :ping, add_to_list: true },
      )
    end
  end
end

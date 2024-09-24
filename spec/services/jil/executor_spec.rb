RSpec.describe Jil::Executor do
  include ActiveJob::TestHelper
  let(:execute) { described_class.call(user, code, input_data) }
  let(:user) { User.me }
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

  describe "Btn Receiver" do
    let!(:receiver) {
      JilTask.create(
        name: "Btn Receiver",
        listener: "websocket:receive",
        code: receiver_code,
        user: User.me,
      )
    }
    let(:receiver_code) {
      <<-JIL
        input = Global.input_data()::Hash
        channel = input.get("channel_id")::String
        btn = input.get("btn_id")::String
        u1fad = Global.print("\#{input}")::String
        data = Hash.new({
          ycd2a = Keyval.new("rgb", "0,40,150")::Keyval
          b2075 = Keyval.new("for_ms", "1500")::Keyval
          wa198 = Keyval.new("flash", "")::Keyval
        })::Hash
        l008c = Global.print("\#{channel}:\#{btn}")::String
        r5e2a = Global.if({
          ke292 = Boolean.eq(channel, "desk")::Boolean
        }, {
          mba58 = Global.if({
            sb48d = btn.match("busp")::Boolean
          }, {
            v6e62 = ActionEvent.add("Auvelity", "", "", "")::ActionEvent
            f7e22 = Global.exit()::Any
          }, {})::Any
          fcb22 = Global.if({
            vada9 = btn.match("water")::Boolean
          }, {
            gb704 = ActionEvent.add("Water", "", "", "")::ActionEvent
            k8447 = Global.exit()::Any
          }, {})::Any
          feef9 = Global.if({
            i0011 = btn.match("soda")::Boolean
          }, {
            s4a23 = ActionEvent.add("Soda", "Mountain Dew", "", "")::ActionEvent
            la9b8 = Global.exit()::Any
          }, {})::Any
          u91d6 = Global.if({
            pb4c1 = btn.match("protein")::Boolean
          }, {
            ocsstart = Hash.keyval("ocs", "start")::Hash
            cb42d = Global.trigger("ocs", ocsstart)::Numeric
            p05dd = Global.exit()::Any
          }, {})::Any
        }, {})::Any
        cc1e7 = Global.if({
          pfb53 = btn.match("teeth")::Boolean
        }, {
          d4425 = ActionEvent.add("Teeth", "", "", "")::ActionEvent
          f1630 = Global.exit()::Any
        }, {})::Any
        gfe60 = Global.if({
          p1a39 = btn.match("laundry")::Boolean
        }, {
          ycdd3 = Hash.keyval("laundry", "start")::Hash
          f2d3e = Global.trigger("laundry", ycdd3)::Numeric
          o822f = Global.exit()::Any
        }, {})::Any
        k6b27 = Global.if({
          e0d6d = btn.match("pullups")::Boolean
        }, {
          o4481 = ActionEvent.add("Handstand", "", "", "")::ActionEvent
          i746d = Global.exit()::Any
        }, {})::Any
      JIL
    }

    describe "with an irrelevant trigger" do
      let(:trigger_data) {
        {
          channel: "SocketChannel",
          user_id: 1,
          channel_id: "garage",
          state: "closed",
          connection_state: "receive",
          match_list: [],
          named_captures: {},
        }
      }

      it "triggers the task but has no side effects" do
        exe = receiver.execute(trigger_data)

        expect(ActionEvent.count).to eq(0)
        expect(exe.ctx.dig(:vars, :k6b27)).to be_present
        expect(exe.ctx.dig(:input_data, :channel)).to eq("SocketChannel")
        expect(exe.ctx.dig(:input_data, :channel_id)).to eq("garage")
      end
    end

    describe "with a relevant trigger" do
      let(:trigger_data) {
        {
          channel: "SocketChannel",
          user_id: 1,
          channel_id: "teeth",
          btn_id: "teeth",
          connection_state: "receive",
          match_list: [],
          named_captures: {},
        }
      }

      it "triggers the second task and completes" do
        exe = receiver.execute(trigger_data)

        expect(ActionEvent.count).to eq(1)
        expect(ActionEvent.first.name).to eq("Teeth")
        expect(exe.ctx.dig(:vars, :k6b27)).not_to be_present
        expect(exe.ctx.dig(:input_data, :channel)).to eq("SocketChannel")
        expect(exe.ctx.dig(:input_data, :channel_id)).to eq("teeth")
      end
    end
  end

  describe "Duration" do
    let!(:func) {
      JilTask.create(
        name: "Duration",
        listener: 'function("From" Date?:Start "To" Date:End "Figs" Numeric(1):SigFigs)::String',
        code: func_code,
        user: User.me,
      )
    }
    let(:func_code) {
      <<-JIL
        now = Date.now()::Numeric
        ge783 = Global.params()::Array
        tbdab = ge783.splat({
          maybeStart = Global.Item()::Any
          end = Global.Item()::Numeric
          sigfigs = Global.Item()::Numeric
        })::Array
        start = Boolean.or(maybeStart, now)::Numeric
        l92c9 = Numeric.op(end, "-", start)::Numeric
        diff = l92c9.abs()::Numeric
        j5f2e = Hash.new({
          j3107 = Keyval.new("w", "604800")::Keyval
          gea82 = Keyval.new("d", "86400")::Keyval
          wbcc4 = Keyval.new("h", "3600")::Keyval
          d75ca = Keyval.new("m", "60")::Keyval
          i9522 = Keyval.new("s", "1")::Keyval
        })::Hash
        left = Global.set!("left", diff)::Numeric
        lengths = Global.set!("lengths", "")::String
        q7ed4 = j5f2e.each({
          time = Global.Key()::String
          seconds = Global.Value()::Numeric
          r64d9 = Global.print("\#{time}=\#{seconds}")::String
          nf9ca = lengths.split(" ")::Array
          v70fb = nf9ca.length()::Numeric
          vd626 = Global.if({
            aad68 = Boolean.compare(v70fb, ">=", sigfigs)::Boolean
            me715 = Boolean.compare(seconds, ">=", left)::Boolean
            zb2d1 = Boolean.or(aad68, me715)::Boolean
          }, {
            g08da = Global.print("NEXT \#{time} \#{v70fb} >= \#{sigfigs} OR \#{seconds} >= \#{left}")::String
            k4a68 = Global.Next("")::None
          }, {
            e2268 = Global.print("ELSE \#{time} \#{v70fb} >= \#{sigfigs} OR \#{seconds} >= \#{left}")::String
          })::Any
          x6f9b = Numeric.op(left, "/", seconds)::Numeric
          count = x6f9b.floor()::Numeric
          less = Numeric.op(count, "*", seconds)::Numeric
          h3d90 = left.op!("-=", less)::Numeric
          w3875 = Global.set!("lengths", "\#{lengths} \#{count}\#{time}")::Any
        })::Hash
        g5c18 = Boolean.or(lengths, "0")::String
        j23d8 = g5c18.format("squish")::String
        ia9d7 = Global.return(j23d8)::String
      JIL
    }
    let(:code) {
      <<-JIL
        time = String.new("#{Time.new(2024, 7, 22, 9, 19, 17)}")::Date
        dur = Custom.Duration("", time, 1)::String
        abc = Global.return(dur)::String
      JIL
    }

    it "returns the duration" do
      travel_to(Time.new(2024, 7, 22, 8, 43, 34)) do
        exe = execute
        val = exe.ctx[:return_val]
        expect(val).to eq("35m")
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
#   // #qloop(content(["Break"::Any "Next"::Any "Index"::Numeric]))::Numeric
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
#   #dowhile(content(["Break"::Any "Next"::Any "Index"::Numeric]))::Numeric
#   #loop(content(["Break"::Any "Next"::Any "Index"::Numeric]))::Numeric
#   #times(Numeric content(["Break"::Any "Next"::Any "Index"::Numeric]))::Numeric
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

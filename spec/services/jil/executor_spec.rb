require "rails_helper"

RSpec.describe Jil::Executor do
  describe "executing" do
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
        Task.create(
          name:     "Btn Receiver",
          listener: "websocket:receive",
          code:     receiver_code,
          user:     User.me,
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
              v6e62 = ActionEvent.add("Auvelity")::ActionEvent
              f7e22 = Global.exit()::Any
            }, {})::Any
            fcb22 = Global.if({
              vada9 = btn.match("water")::Boolean
            }, {
              gb704 = ActionEvent.add("Water")::ActionEvent
              k8447 = Global.exit()::Any
            }, {})::Any
            feef9 = Global.if({
              i0011 = btn.match("soda")::Boolean
            }, {
              s8ff0 = ActionEvent.create({
                jd135 = ActionEventData.name("Soda")::ActionEventData
                n2a70 = ActionEventData.notes("Mountain Dew")::ActionEventData
              })::ActionEvent
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
            d4425 = ActionEvent.add("Teeth")::ActionEvent
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
            o4481 = ActionEvent.add("Handstand")::ActionEvent
            i746d = Global.exit()::Any
          }, {})::Any
        JIL
      }

      describe "with an irrelevant trigger" do
        let(:trigger_data) {
          {
            channel:          "SocketChannel",
            user_id:          1,
            channel_id:       "garage",
            state:            "closed",
            connection_state: "receive",
            match_list:       [],
            named_captures:   {},
          }
        }

        it "triggers the task but has no side effects" do
          exe = receiver.execute(trigger_data)

          expect(ActionEvent.count).to eq(0)
          expect(exe.ctx.dig(:vars, :k6b27)).to be_present
          expect(exe.input_data[:channel]).to eq("SocketChannel")
          expect(exe.input_data[:channel_id]).to eq("garage")
        end
      end

      describe "with a relevant trigger" do
        let(:trigger_data) {
          {
            channel:          "SocketChannel",
            user_id:          1,
            channel_id:       "teeth",
            btn_id:           "teeth",
            connection_state: "receive",
            match_list:       [],
            named_captures:   {},
          }
        }

        it "triggers the second task and completes" do
          exe = receiver.execute(trigger_data)

          expect(ActionEvent.count).to eq(1)
          expect(ActionEvent.first.name).to eq("Teeth")
          expect(exe.ctx.dig(:vars, :k6b27)).not_to be_present
          expect(exe.input_data[:channel]).to eq("SocketChannel")
          expect(exe.input_data[:channel_id]).to eq("teeth")
        end
      end
    end

    describe "Duration" do
      let!(:func) {
        Task.create(
          name:     "Duration",
          listener: 'function("From" Date?:Start "To" Date:End "Figs" Numeric(1):SigFigs)::String',
          code:     func_code,
          user:     User.me,
        )
      }
      let(:func_code) {
        <<-JIL
          now = Date.now()::Numeric
          ge783 = Global.params()::Array
          tbdab = ge783.splat({
            maybeStart = Keyword.Item()::Any
            end = Keyword.Item()::Numeric
            sigfigs = Keyword.Item()::Numeric
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
            time = Keyword.Key()::String
            seconds = Keyword.Value()::Numeric
            r64d9 = Global.print("\#{time}=\#{seconds}")::String
            nf9ca = lengths.split(" ")::Array
            v70fb = nf9ca.length()::Numeric
            vd626 = Global.if({
              aad68 = Boolean.compare(v70fb, ">=", sigfigs)::Boolean
              me715 = Boolean.compare(seconds, ">=", left)::Boolean
              zb2d1 = Boolean.or(aad68, me715)::Boolean
            }, {
              g08da = Global.print("NEXT \#{time} \#{v70fb} >= \#{sigfigs} OR \#{seconds} >= \#{left}")::String
              k4a68 = Keyword.Next("")::None
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
          time = String.new("#{Time.zone.local(2024, 7, 22, 9, 19, 17)}")::Date
          dur = Custom.Duration("", time, 1)::String
          abc = Global.return(dur)::String
        JIL
      }

      it "returns the duration" do
        travel_to(Time.zone.local(2024, 7, 22, 8, 43, 34)) do
          exe = execute
          val = exe.ctx[:return_val]
          expect(val).to eq("35m")
        end
      end
    end
  end

  describe "auth" do
    let(:user) { FactoryBot.create(:user, phone: "5559990010") }
    let(:code) {
      <<~JIL
        out = Global.print("hello")::String
      JIL
    }

    describe "auth_type / auth_type_id / trigger_scope" do
      it "stores auth and trigger_scope passed to .call" do
        described_class.call(
          user, code, {},
          auth: :run, auth_id: user.id, trigger_scope: :ui_run
        )

        execution = Execution.last
        expect(execution.auth_type).to eq("run")
        expect(execution.auth_type_id).to eq(user.id)
        expect(execution.trigger_scope).to eq("ui_run")
      end

      it "leaves columns blank when not provided" do
        described_class.call(user, code, {})

        execution = Execution.last
        expect(execution.auth_type).to be_nil
        expect(execution.auth_type_id).to be_nil
        expect(execution.trigger_scope).to be_nil
      end

      it "auto-derives trigger_scope from the listener trigger" do
        task = user.tasks.create!(name: "myscope task", listener: "myscope", code: code, enabled: true)

        described_class.trigger(user, :myscope, {})

        execution = task.reload.executions.order(:id).last
        expect(execution).to be_present
        expect(execution.auth_type).to eq("trigger")
        expect(execution.trigger_scope).to eq("myscope")
      end

      it "carries auth_id from Jil.trigger to Execution row" do
        task = user.tasks.create!(name: "scoped task", listener: "scoped", code: code, enabled: true)

        Jil.trigger(user, :scoped, {}, auth: :trigger, auth_id: 42_424_242)

        execution = task.reload.executions.order(:id).last
        expect(execution).to be_present
        expect(execution.auth_type).to eq("trigger")
        expect(execution.auth_type_id).to eq(42_424_242)
        expect(execution.trigger_scope).to eq("scoped")
      end

      it "tags cron-fired executions with auth_type=cron via Task#execute" do
        task = user.tasks.create!(name: "cron task", listener: "cronnish", code: code, enabled: true)

        task.execute(auth: :cron)

        execution = task.reload.executions.order(:id).last
        expect(execution.auth_type).to eq("cron")
        expect(execution.auth_type_id).to be_nil
      end
    end

    describe "auth_record / auth_label" do
      it "resolves a Task source for :trigger" do
        source_task = user.tasks.create!(name: "src", listener: "src_lis", code: code, enabled: true)
        execution = Execution.create!(user: user, auth_type: :trigger, auth_type_id: source_task.id)

        expect(execution.auth_record).to eq(source_task)
        expect(execution.auth_label).to eq("Task##{source_task.id}")
      end

      it "resolves a User source for :userpass" do
        execution = Execution.create!(user: user, auth_type: :userpass, auth_type_id: user.id)

        expect(execution.auth_record).to eq(user)
        expect(execution.auth_label).to eq("User##{user.id}")
      end

      it "returns nil record and labels by enum for :cron" do
        execution = Execution.create!(user: user, auth_type: :cron)

        expect(execution.auth_record).to be_nil
        expect(execution.auth_label).to eq("cron")
      end

      it "labels with auth_type when no class mapping but id present" do
        execution = Execution.create!(user: user, auth_type: :cron, auth_type_id: 5)

        expect(execution.auth_label).to eq("cron#5")
      end

      it "labels as 'unknown' when auth_type and auth_type_id are both blank" do
        execution = Execution.create!(user: user)

        expect(execution.auth_label).to eq("unknown")
      end

      it "labels :words as plain auth_type with no id" do
        execution = Execution.create!(user: user, auth_type: :words)

        expect(execution.auth_record).to be_nil
        expect(execution.auth_label).to eq("words")
      end
    end
  end

  describe "payloads" do
    let(:user) { FactoryBot.create(:user, phone: "5559990002") }
    let(:code) {
      <<~JIL
        out = Global.print("hello")::String
      JIL
    }

    it "writes code/input_data/ctx to ExecutionPayload, not directly on Execution" do
      expect { described_class.call(user, code, { foo: "bar" }) }.to change(ExecutionPayload, :count).by(1)

      execution = Execution.last
      expect(execution.payload_id).to be_present
      expect(execution.code).to eq(code)
      expect(execution.input_data).to include("foo" => "bar")
      expect(execution.ctx).to include("output" => ["hello"])
    end

    it "does not run inline compaction on initialize" do
      11.times { described_class.call(user, code, {}) }

      expect(ExecutionPayload.count).to eq(11)
      expect(Execution.where.not(payload_id: nil).count).to eq(11)
    end

    # A camera frame reaches Jil as ~500KB of base64 sitting in a var, so what
    # gets done with vars stopped being free. `store_progress` writes
    # `ctx.except(:vars)` and `broadcast!` sends five named keys — neither carries
    # a value. Including vars in either would write half a megabyte into
    # execution_payloads and push it down the socket on EVERY snapshot request,
    # 32 times over, since execute_line broadcasts per line.
    it "keeps var values out of the stored payload and off the socket" do
      big = "x" * 200_000
      allow_any_instance_of(Jil::Methods::Global).to receive(:request).and_return(
        code: 200, body: { "frame" => big },
      )
      broadcasts = []
      allow(TasksChannel).to receive(:send_to) { |_u, _uuid, data| broadcasts << data }

      described_class.call(user, <<~'JIL', {})
        res = Global.request("GET", "http://example.test", {}, {})::Hash
        huge = res.get("frame")::String
        out = Global.return("done")::String
      JIL

      payload = Execution.last.payload
      expect(payload.code.bytesize).to be < 1_000
      expect(payload.ctx.to_json).not_to include(big)
      expect(broadcasts.map(&:to_json).join).not_to include(big)
    end

    it "exposes ctx-derived helpers through the payload" do
      described_class.call(user, code, {})
      execution = Execution.last
      expect(execution.output).to eq(["hello"])
      expect(execution.error).to be_nil
    end
  end

  # Reproduces the bug where external Run-button POSTs (which arrive as string-keyed
  # hashes after Sidekiq's JSON roundtrip) silently delivered nil to
  # Global.functionParams positional binders that look up dig(:params).
  describe "external run input data" do
    let(:user) { User.me }

    let(:code) {
      <<~'JIL'
        params = Global.functionParams({
          color = Keyword.Item()::String
        })::Array
        out = Global.return(color)::String
      JIL
    }

    it "binds positional args from a string-keyed input_data hash" do
      string_keyed = { "params" => ["White"], "Color" => "White" }
      exe = described_class.call(user, code, string_keyed)
      expect(exe.result).to eq("White")
    end

    it "binds positional args from a symbol-keyed input_data hash" do
      symbol_keyed = { params: ["Blue"] }
      exe = described_class.call(user, code, symbol_keyed)
      expect(exe.result).to eq("Blue")
    end

    it "binds NamedArg lookups from a string-keyed input_data hash" do
      named_code = <<~'JIL'
        params = Global.functionParams({
          person = Keyword.NamedArg("person")::String
        })::Array
        out = Global.return(person)::String
      JIL
      exe = described_class.call(user, named_code, { "person" => "Alice", "params" => ["Alice"] })
      expect(exe.result).to eq("Alice")
    end

    # Regression: 0e6b39fd wrapped input_data in .with_indifferent_access
    # unconditionally, which exploded on AR records and silently dropped every
    # event:add / agenda_item / chore_completion listener trigger.
    it "accepts an ApplicationRecord as input_data (Jilable trigger path)" do
      event = ActionEvent.create!(user: user, name: "Whisper", notes: "Nap")
      record_code = <<~'JIL'
        evt = Global.input_data()::ActionEvent
        act = evt.notes()::String
        out = Global.return(act)::String
      JIL
      exe = described_class.call(user, record_code, event.with_jil_attrs(action: :added))
      expect(exe.result).to eq("Nap")
    ensure
      event&.destroy
    end
  end
end

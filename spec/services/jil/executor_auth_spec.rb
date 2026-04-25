RSpec.describe Jil::Executor do
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

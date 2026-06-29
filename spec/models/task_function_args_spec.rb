require "rails_helper"

RSpec.describe Task, type: :model do
  let(:user) { User.me }

  def build_task(listener)
    Task.new(user: user, name: "T", listener: listener, code: "")
  end

  describe "#function?" do
    it "is true for function listener" do
      expect(build_task("function()").function?).to eq(true)
      expect(build_task("function(name:String)").function?).to eq(true)
      expect(build_task("function(content([a:String]))::Hash").function?).to eq(true)
    end

    it "is false for non-function listeners" do
      expect(build_task("email:from:hunter").function?).to eq(false)
      expect(build_task("monitor:laundry").function?).to eq(false)
      expect(build_task(nil).function?).to eq(false)
      expect(build_task("").function?).to eq(false)
    end
  end

  describe "#function_args_str" do
    it "returns nil for non-functions" do
      expect(build_task("email:from:hunter").function_args_str).to be_nil
      expect(build_task(nil).function_args_str).to be_nil
    end

    it "returns nil for function() with no args" do
      expect(build_task("function()").function_args_str).to be_nil
      expect(build_task("function()::Hash").function_args_str).to be_nil
    end

    it "returns raw args string for simple named typed args" do
      expect(build_task("function(name:String age:Numeric)").function_args_str).to eq("name:String age:Numeric")
    end

    it "preserves content block args verbatim" do
      str = "function(content([person:String deposit:Numeric note:Text]))"
      expect(build_task(str).function_args_str).to eq("content([person:String deposit:Numeric note:Text])")
    end

    it "preserves TAB/BR formatting tokens" do
      str = 'function("Start Event ID" TAB Numeric BR "New Filament" TAB String)::Hash'
      expect(build_task(str).function_args_str).to eq('"Start Event ID" TAB Numeric BR "New Filament" TAB String')
    end
  end
end

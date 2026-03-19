RSpec.describe "ESPLED alternating case bug" do
  let(:user) { User.me }

  let!(:broadcast_task) {
    user.tasks.create!(
      name: "BroadcastESP",
      listener: "function()",
      enabled: true,
      code: 'ret = Global.return("ok")::Any',
    )
  }

  let!(:espled_task) {
    user.tasks.create!(
      name: "ESPLED",
      listener: "function()",
      enabled: true,
      code: <<-'JIL',
        f9caf = Global.functionParams({
          givenColor = Keyword.NamedArg("color")::String
          givenRgb = Keyword.NamedArg("rgb")::String
        })::Array
        initialColor = Boolean.or(givenColor, givenRgb)::String
        rgb = Global.case(initialColor, {
          a1 = Keyword.When("Blue", {
            b1 = String.new("1,96,255")::String
          })::Any
          a2 = Keyword.When("Red", {
            b2 = String.new("180,15,10")::String
          })::Any
          a3 = Keyword.Else({
            b3 = String.new("0,40,150")::String
          })::Any
        })::String
        ret = Global.return(rgb)::Any
      JIL
    )
  }

  after { broadcast_task.destroy; espled_task.destroy }

  it "does not alternate failures across multiple runs" do
    5.times do |i|
      exe = ::Jil::Executor.call(user, <<-'JIL', {})
        aff8c = Custom.ESPLED({
          y327c = Keyword.color("Blue")::String
        })::Any
      JIL
      expect(exe.ctx[:error]).to be_blank, "Run #{i + 1} failed: #{exe.ctx[:error]}"
    end
  end
end

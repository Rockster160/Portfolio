RSpec.describe ::Jarvis::MatchTask do
  let(:user) { User.create(id: 1, username: "Admin", role: :admin, password: :password, password_confirmation: :password) }
  def find_match(str) = Jarvis::MatchTask.find_match(user, str)
  def match_run(str) = Jarvis::MatchTask.match_run(user, str)

  describe ".find_match" do
    it "finds with not exact matching common words" do
      task = JarvisTask.create(input: "Set the house to {temp:/\d+/} (degrees) (this|that|other) (!this|matters) {rest}", user: user, trigger: :tell)
      expect(find_match("Set the house 72 degrees matters more")).to eq(task)
    end
  end

  describe ".match_run" do
    it "finds with not exact matching common words" do
      task = JarvisTask.create(
        user: user,
        trigger: :tell,
        input: "Set the house to {temp:/\\d+/} (degrees) (this|that|other) (!this|matters) {rest}\nChange to {temp} (please)"
      )
      expect(Jarvis::Text::AFFIRMATIVE_RESPONSES).to include(match_run("Set the house 72 degrees other this more"))
    end
  end
end

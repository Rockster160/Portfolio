RSpec.describe ::Jarvis::MatchTask do
  let(:user) { User.create(username: "Admin", role: :admin, password: :password, password_confirmation: :password) }
  def find_by(str) = Jarvis::MatchTask.find_by(user, str)

  describe ".find_by" do
    it "finds with not exact matching common words" do
      task = JarvisTask.create(name: "Set the house to {temp:/\d+/} (degrees) (this|that|other) (!this|matters) {rest}", user: user)
      expect(find_by("Set the house 72 degrees matters")).to eq(task)
    end
  end
end

RSpec.describe ::Jarvis::Execute do
  let(:user) { User.create(role: :admin) }
  let(:task) { JarvisTask.create(tasks: tasks, user: user) }
  let(:execute) { ::Jarvis::Execute.call(task) }
  let(:tasks) { [] }
  let(:hello) { { type: :print, message: "Hello, World!" } }
  let(:goodbye) { { type: :print, message: "Goodbye, World!" } }

  describe "#math" do
    let(:tasks) {
      [
        {
          type: :if,
          condition: {
            type: :or,
            args: [false, { type: :compare, sign: "==", args: [1, 1] }]
          },
          do: [hello],
          else: [goodbye]
        }
      ]
    }

    it "runs the code" do
      expect(execute).to include("Hello, World!")
      task.reload
      puts "\e[34m#{execute}\e[0m"
      puts "\e[33m#{task.last_ctx}\e[0m"
      puts "\e[31m#{task.attributes}\e[0m"
    end
  end
end

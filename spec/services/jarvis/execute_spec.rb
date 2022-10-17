RSpec.describe ::Jarvis::Execute do
  let(:user) { User.create(role: :admin) }
  let(:task) { JarvisTask.create(tasks: tasks, user: user) }
  let(:execute) { ::Jarvis::Execute.call(task) }
  let(:hello) { { type: :print, message: "Hello, World!" } }
  let(:goodbye) { { type: :print, message: "Goodbye, World!" } }

  describe "#if" do
    let(:tasks) {
      [
        {
          type: :if,
          condition: {
            type: :or,
            args: [false, { type: :compare, sign: "==", args: args }]
          },
          do: [hello],
          else: [goodbye]
        }
      ]
    }

    context "with positive blocks" do
      let(:args) { [1, 1] } # Matching

      specify { expect(execute).to include("Hello, World!") }
    end

    context "with negative blocks" do
      let(:args) { [1, 0] } # NOT matching

      specify { expect(execute).to include("Goodbye, World!") }
    end
  end

  describe "#loops" do
    context "with a basic loop" do
      let(:tasks) {
        [
          {
            type: :loop,
            times: 10,
            do: [hello]
          }
        ]
      }

      it "runs the block X times" do
        expect(execute.count { |i| i == "Hello, World!" }).to eq(10)
      end
    end

    context "with an index block" do
      let(:tasks) {
        [
          {
            type: :loop,
            times: 10,
            do: [
              {
                type: :if,
                condition: {
                  type: :or,
                  args: [false, { type: :compare, sign: ">", args: [5, { type: :index }] }]
                },
                do: [hello],
                else: [goodbye]
              },
            ]
          },
          { type: :print, message: "After loop!" }
        ]
      }

      it "runs the block 5 times" do
        expect(execute.count { |i| i == "Hello, World!" }).to eq(5)
        expect(execute.count { |i| i == "Goodbye, World!" }).to eq(5)
        expect(execute).to include("After loop!")
      end
    end

    context "with an exit block" do
      let(:tasks) {
        [
          { type: :exit },
          { type: :print, message: "After exit!" }
        ]
      }

      it "does not run " do
        expect(execute).to_not include("After exit!")
      end
    end

    context "with overflow" do
      let(:tasks) {
        [
          {
            type: :loop,
            times: 1005,
            do: [
              { type: :index }
            ]
          }
        ]
      }

      it "runs the block 1000 times then errors out" do
        expect(execute.last).to eq("Failed: Blocks exceed 1,000 allowed.")
        expect(task.last_ctx["i"]).to eq(1001) # 1001 because it only errors AFTER exceeding
      end
    end

    context "with max iterations" do
      let(:tasks) {
        [
          {
            type: :loop,
            times: 999, # 999 because the initial loop also counts as a block
            do: [
              { type: :index }
            ]
          }
        ]
      }

      it "runs the block 1000 times without error" do
        expect(execute.last).to eq("Success")
        expect(task.last_ctx["i"]).to eq(1000)
      end
    end
  end

  describe "#vars" do
    let(:tasks) {
      [
        {
          type: :set_var,
          name: "blah blah",
          value: "This is my value!"
        },
        { type: :print, message: { type: :get_var, name: "blah blah" } }
      ]
    }

    it "sets and gets a variable" do
      expect(execute).to match_array(["This is my value!", "Success"])
    end
  end

  # Test each/map loops?
  # Also test cache
  # Test external requests?
end

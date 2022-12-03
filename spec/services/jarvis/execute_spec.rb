RSpec.describe ::Jarvis::Execute do
  let(:user) { User.create(role: :admin) }
  let(:task) { JarvisTask.create(tasks: tasks, user: user) }
  let(:execute) { ::Jarvis::Execute.call(task) }
  let(:hello) { "Hello, World!" }
  let(:goodbye) { "Goodbye, World!" }

  describe "#if" do
    let(:tasks) {
      [
        {
          returntype: :any,
          type: "logic.if",
          token: "desk.monkey.zebra",
          data: [
            [
              {
                returntype: :bool,
                type: "numbers.compare",
                token: "oak.desert.funky",
                data: [
                  { option: :input, raw: "1" },
                  { option: ">" },
                  { option: :input, raw: "5" }
                ]
              }
            ],
            [
              {
                returntype: :str,
                type: "task.print",
                token: "dirty.tree.goto",
                data: [
                  { option: :input, raw: "Hello, World!" }
                ]
              }
            ],
            [
              {
                returntype: :str,
                type: "task.print",
                token: "soft.read.apple",
                data: [
                  { option: :input, raw: "Goodbye, World!" }
                ]
              }
            ]
          ]
        }
      ]
    }

    context "with positive blocks" do
      let(:args) { [1, 1] } # Matching

      specify { expect(execute).to include(hello) }
    end

    context "with negative blocks" do
      let(:args) { [1, 0] } # NOT matching

      specify { expect(execute).to include(goodbye) }
    end
  end

  describe "#loops" do
    context "with a basic loop" do
      let(:tasks) {
        [
          {
            returntype: :num,
            type: "logic.times",
            token: "aphid.saloon.dirty",
            data: [
              {
                option: :input,
                raw: "10"
              },
              [
                {
                  returntype: :str,
                  type: "task.print",
                  token: "stand.frost.town",
                  data: [
                    {
                      option: :input,
                      raw: "Hello, World!"
                    }
                  ]
                }
              ]
            ]
          }
        ]
      }

      it "runs the block X times" do
        expect(execute.count { |i| i == hello }).to eq(10)
      end
    end

    context "with an index block" do
      # FIXME!! Dropdowns don't show values for other blocks in the same :content
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
        expect(execute.count { |i| i == hello }).to eq(5)
        expect(execute.count { |i| i == goodbye }).to eq(5)
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
        expect(task.last_ctx[:i]).to eq(1001) # 1001 because it only errors AFTER exceeding
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
        expect(execute.last).to eq(:Success)
        expect(task.last_ctx[:i]).to eq(1000)
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
      expect(execute).to match_array(["This is my value!", :Success])
    end
  end

  # Test each/map loops?
  # Also test cache
  # Test external requests?
end

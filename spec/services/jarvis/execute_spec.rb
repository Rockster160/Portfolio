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
                type: "math.compare",
                token: "oak.desert.funky",
                data: [
                  { option: :input, raw: args[0] },
                  { option: "==" },
                  { option: :input, raw: args[1] }
                ]
              }
            ],
            [
              {
                returntype: :str,
                type: "task.print",
                token: "dirty.tree.goto",
                data: [
                  { option: :input, raw: hello }
                ]
              }
            ],
            [
              {
                returntype: :str,
                type: "task.print",
                token: "soft.read.apple",
                data: [
                  { option: :input, raw: goodbye }
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
                      raw: hello
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
      let(:tasks) {
        [
          {
            returntype: :num,
            type: "logic.times",
            token: "apple.shiny.car",
            data: [
              { option: :input, raw: "10" },
              [
                {
                  returntype: :num,
                  type: "logic.index",
                  token: "limp.town.wash",
                  data: []
                },
                {
                  returntype: :any,
                  type: "logic.if",
                  token: "soft.carrot.frost",
                  data: [
                    [
                      {
                        returntype: :bool,
                        type: "math.compare",
                        token: "shrimp.danish.bed",
                        data: [
                          { option: :input, raw: "5" },
                          { option: ">" },
                          { option: "limp.town.wash" }
                        ]
                      }
                    ],
                    [
                      {
                        returntype: :str,
                        type: "task.print",
                        token: "shiny.shiny.ocean",
                        data: [
                          { option: :input, raw: hello }
                        ]
                      }
                    ],
                    [
                      {
                        returntype: :str,
                        type: "task.print",
                        token: "dog.wash.town",
                        data: [
                          { option: :input, raw: goodbye }
                        ]
                      }
                    ]
                  ]
                }
              ]
            ]
          },
          {
            returntype: :str,
            type: "task.print",
            token: "cat.bisquit.saloon",
            data: [
              { option: :input, raw: "After loop!" }
            ]
          }
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
          {
            returntype: "str",
            type: "task.print",
            token: "heavy.limp.push",
            data: [
              { option: "input", raw: "Before exit!" }
            ]
          },
          {
            returntype: "any",
            type: "task.exit",
            token: "saloon.push.saloon"
          },
          {
            returntype: "str",
            type: "task.print",
            token: "heavy.limp.push",
            data: [
              { option: "input", raw: "After exit!" }
            ]
          }
        ]
      }

      it "does not run " do
        expect(execute).to include("Before exit!")
        expect(execute).to_not include("After exit!")
      end
    end

    context "with overflow" do
      let(:tasks) {
        [
          {
            returntype: "num",
            type: "logic.times",
            token: "apple.shiny.car",
            data: [
              { option: "input", raw: "1005" },
              [
                {
                  returntype: "num",
                  type: "logic.index",
                  token: "bed.blue.purple"
                }
              ]
            ]
          }
        ]
      }

      it "runs the block 1000 times then errors out" do
        expect(execute.last).to include("Failed: Blocks exceed 1,000 allowed.")
        expect(task.last_ctx[:i]).to eq(1001) # 1001 because it only errors AFTER exceeding
      end
    end

    context "with max iterations" do
      let(:tasks) {
        [
          {
            returntype: "num",
            type: "logic.times",
            token: "apple.shiny.car",
            data: [
              { option: "input", raw: "999" }, # 999 because the initial loop also counts as a block
              [
                {
                  returntype: "num",
                  type: "logic.index",
                  token: "bed.blue.purple"
                }
              ]
            ]
          }
        ]
      }

      it "runs the block 1000 times without error" do
        expect(execute.last).to eq("Success")
        expect(task.last_ctx[:i]).to eq(1000)
      end
    end
  end

  describe "#vars" do
    let(:tasks) {
      [
        {
          returntype: "str",
          type: "raw.str",
          token: "soft.frost.cable",
          data: [
            { option: "input", raw: "This is my value!" }
          ]
        },
        {
          returntype: "var",
          type: "raw.set_var",
          token: "wine.wine.wine",
          data: [
            { option: "input", raw: "blah blah" },
            { option: "soft.frost.cable" }
          ]
        },
        {
          returntype: "var",
          type: "raw.get_var",
          token: "grow.eclair.zebra",
          data: [
            { option: "input", raw: "blah blah" }
          ]
        },
        {
          returntype: "str",
          type: "text.cast",
          token: "aphid.monkey.apple",
          data: [
            { option: "grow.eclair.zebra" }
          ]
        },
        {
          returntype: "str",
          type: "task.print",
          token: "limp.ocean.stand",
          data: [
            { option: "aphid.monkey.apple" }
          ]
        }
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

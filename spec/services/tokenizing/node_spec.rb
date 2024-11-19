# load("/Users/rocco/.pryrc"); pretty_puts(node.as_json)
RSpec.describe Tokenizing::Node, type: :model do
  describe ".parse" do
    it "parses complex expressions with AND, OR, and nested conditions" do
      node = Tokenizing::Node.parse("price > 10 AND price < 20 (Potter OR Rowling) name::food:cereal data=>exact data->partial")
      expect(node.as_json).to eq({
        field: nil,
        operator: "AND".to_sym,
        conditions: [
          { field: "price", operator: ">".to_sym, conditions: "10" },
          { field: "price", operator: "<".to_sym, conditions: "20" },
          { field: nil, operator: "OR".to_sym, conditions: ["Potter", "Rowling"] },
          { field: "name", operator: "::".to_sym, conditions: [
            { field: "food", operator: ":".to_sym, conditions: "cereal" },
          ]},
          { field: "data", operator: "=>".to_sym, conditions: "exact" },
          { field: "data", operator: "->".to_sym, conditions: "partial" },
        ]
      })
    end

    it "properly nests paren expressions" do
      node = Tokenizing::Node.parse("name:('Z*')")
      expect(node.as_json).to eq({
        field: "name",
        operator: ":".to_sym,
        conditions: "Z*"
      })
    end

    it "properly nests multiple paren expressions" do
      node = Tokenizing::Node.parse("name:(Workout OR Z OR 'Z*')")
      expect(node.as_json).to eq({
        field: "name",
        operator: ":".to_sym,
        conditions: [
          {
            field: nil,
            operator: "OR".to_sym,
            conditions: [
              "Workout",
              "Z",
              "Z*",
            ]
          },
        ]
      })
    end

    it "parses expressions with OR and AND operators" do
      node = Tokenizing::Node.parse("Potter OR Rowling AND price < 20 name:\"Hello, World!\" OR name:\"Goodbye\"")
      expect(node.as_json).to eq({
        field: nil,
        operator: "AND".to_sym,
        conditions: [
          {
            field: nil,
            operator: "OR".to_sym,
            conditions: ["Potter", "Rowling"]
          },
          {
            field: nil,
            operator: "OR".to_sym,
            conditions: [
              {
                field: nil,
                operator: "AND".to_sym,
                conditions: [
                  { field: "price", operator: "<".to_sym, conditions: "20" },
                  { field: "name", operator: ":".to_sym, conditions: "Hello, World!" }
                ]
              },
              { field: "name", operator: ":".to_sym, conditions: "Goodbye" }
            ]
          }
        ]
      })
    end

    it "parses expressions with NOT operator" do
      node = Tokenizing::Node.parse("price < 20 AND price > 10 -Potter")
      expect(node.as_json).to eq({
        field: nil,
        operator: "AND".to_sym,
        conditions: [
          { field: "price", operator: "<".to_sym, conditions: "20" },
          { field: "price", operator: ">".to_sym, conditions: "10" },
          { field: nil, operator: "NOT".to_sym, conditions: "Potter" }
        ]
      })
    end

    it "parses expressions with nested NOT and OR operators" do
      node = Tokenizing::Node.parse("price < 20 price > 10 -(Potter OR Rowling)")
      expect(node.as_json).to eq({
        field: nil,
        operator: "AND".to_sym,
        conditions: [
          { field: "price", operator: "<".to_sym, conditions: "20" },
          { field: "price", operator: ">".to_sym, conditions: "10" },
          {
            field: nil,
            operator: "NOT".to_sym,
            conditions: [
              {
                field: nil,
                operator: "OR".to_sym,
                conditions: ["Potter", "Rowling"]
              }
            ]
          }
        ]
      })
    end

    it "parses a single expression" do
      node = Tokenizing::Node.parse("Wordle")
      expect(node.as_json).to eq({
        field: "Wordle",
        operator: nil,
        conditions: [],
      })
    end

    it "parses expressions with just words and a comparison" do
      node = Tokenizing::Node.parse("Wordle timestamp>'2024-11-19T00:00:00-07:00'")
      expect(node.as_json).to eq({
        field: nil,
        operator: "AND".to_sym,
        conditions: [
          "Wordle",
          { field: "timestamp", operator: ">".to_sym, conditions: "2024-11-19T00:00:00-07:00" },
        ]
      })
    end

    it "respects any level of nested parens" do
      node = Tokenizing::Node.parse("(timestamp<'2019-01-01') AND (name::(Workout OR Z OR 'Z*') OR name::(Food Treat))")
      expect(node.as_json).to eq({
        field: nil,
        operator: :AND,
        conditions: [
          {
            field: "timestamp",
            operator: "<".to_sym,
            conditions: "2019-01-01",
          }, {
            field: nil,
            operator: :OR,
            conditions: [
              {
                field: "name",
                operator: "::".to_sym,
                conditions: [{ field: nil, operator: :OR, conditions: ["Workout", "Z", "Z*"] }],
              }, {
                field: "name",
                operator: "::".to_sym,
                conditions: [{ field: nil, operator: :AND, conditions: ["Food", "Treat"] }],
              }
            ]
          }
        ]
      })
    end

    it "parses nested values properly" do
      node = Tokenizing::Node.parse(
        "timestamp>'2024-11-12 07:00:00' AND (name::(Workout OR Z) OR name::(Food OR Treat))",
      )
      expect(node.as_json).to eq({
        field: nil,
        operator: :AND,
        conditions: [
          { field: "timestamp", operator: ">".to_sym, conditions: "2024-11-12 07:00:00" },
          {
            field: nil,
            operator: :OR,
            conditions: [
              {
                field: "name",
                operator: "::".to_sym,
                conditions: [{ field: nil, operator: :OR, conditions: ["Workout", "Z"] }],
              },
              {
                field: "name",
                operator: "::".to_sym,
                conditions: [{ field: nil, operator: :OR, conditions: ["Food", "Treat"] }],
              }
            ]
          }
        ]
      })
    end
  end
end

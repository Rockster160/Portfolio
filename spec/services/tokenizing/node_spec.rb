RSpec.describe Tokenizing::Node, type: :model do
  describe ".parse" do
    it "parses complex expressions with AND, OR, and nested conditions" do
      node = Tokenizing::Node.parse("price > 10 AND price < 20 (Potter OR Rowling) name::food:cereal data=>exact data->partial")
      expect(node.as_json).to eq({
        field: nil,
        operator: "AND".to_sym,
        conditions: [
          {
            field: "price",
            operator: ">".to_sym,
            conditions: "10"
          },
          {
            field: "price",
            operator: "<".to_sym,
            conditions: "20"
          },
          {
            field: nil,
            operator: "OR".to_sym,
            conditions: [
              "Potter",
              "Rowling"
            ]
          },
          {
            field: "name",
            operator: "::".to_sym,
            conditions: [
              {
                field: "food",
                operator: ":".to_sym,
                conditions: "cereal"
              }
            ]
          },
          {
            field: "data",
            operator: "=>".to_sym,
            conditions: "exact"
          },
          {
            field: "data",
            operator: "->".to_sym,
            conditions: "partial"
          }
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
            conditions: [
              "Potter",
              "Rowling"
            ]
          },
          {
            field: nil,
            operator: "OR".to_sym,
            conditions: [
              {
                field: nil,
                operator: "AND".to_sym,
                conditions: [
                  {
                    field: "price",
                    operator: "<".to_sym,
                    conditions: "20"
                  },
                  {
                    field: "name",
                    operator: ":".to_sym,
                    conditions: "Hello, World!"
                  }
                ]
              },
              {
                field: "name",
                operator: ":".to_sym,
                conditions: "Goodbye"
              }
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
          {
            field: "price",
            operator: "<".to_sym,
            conditions: "20"
          },
          {
            field: "price",
            operator: ">".to_sym,
            conditions: "10"
          },
          {
            field: nil,
            operator: "NOT".to_sym,
            conditions: "Potter"
          }
        ]
      })
    end

    it "parses expressions with nested NOT and OR operators" do
      node = Tokenizing::Node.parse("price < 20 price > 10 -(Potter OR Rowling)")
      expect(node.as_json).to eq({
        field: nil,
        operator: "AND".to_sym,
        conditions: [
          {
            field: "price",
            operator: "<".to_sym,
            conditions: "20"
          },
          {
            field: "price",
            operator: ">".to_sym,
            conditions: "10"
          },
          {
            field: nil,
            operator: "NOT".to_sym,
            conditions: [
              {
                field: nil,
                operator: "OR".to_sym,
                conditions: [
                  "Potter",
                  "Rowling"
                ]
              }
            ]
          }
        ]
      })
    end
  end
end

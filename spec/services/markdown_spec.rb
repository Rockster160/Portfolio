require "rails_helper"

RSpec.describe Markdown do
  def html(text) = described_class.new(text).to_html.to_s

  describe "ordered lists" do
    it "does not wrap a single numbered line in <ol>" do
      expect(html("1. milk")).not_to include("<ol>")
    end

    it "does not wrap a leading number in <ol> for typical list-item text" do
      expect(html("2 eggs")).not_to include("<ol>")
      expect(html("3) party hats")).not_to include("<ol>")
    end

    it "wraps two or more consecutive numbered lines in <ol>" do
      out = html("1. milk\n2. eggs")
      expect(out).to include("<ol>")
      expect(out).to include("<li>milk</li>")
      expect(out).to include("<li>eggs</li>")
    end
  end
end

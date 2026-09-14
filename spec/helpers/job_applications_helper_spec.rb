require "rails_helper"

RSpec.describe JobApplicationsHelper do
  describe "#note_body" do
    it "turns a markdown link into an anchor" do
      html = helper.note_body("[What was sent](http://localhost:8790/jobs/406)")

      expect(html).to eq(
        %(<a href="http://localhost:8790/jobs/406" target="_blank" rel="noopener">What was sent</a>),
      )
    end

    it "links a bare URL, which is what every note written before this has" do
      expect(helper.note_body("See https://example.com/x for it.")).to eq(
        %(See <a href="https://example.com/x" target="_blank" rel="noopener">https://example.com/x</a> for it.),
      )
    end

    # The whole reason the body is not run through `simple_format`.
    it "leaves the text alone, indentation included" do
      expect(helper.note_body("First\n  hung under it\n\nLater")).to eq("First\n  hung under it\n\nLater")
    end

    it "escapes what it does not link" do
      expect(helper.note_body("<script>alert(1)</script>")).to eq("&lt;script&gt;alert(1)&lt;/script&gt;")
    end

    it "escapes a markdown link's own label" do
      expect(helper.note_body("[<b>x</b>](https://example.com)")).to include("&lt;b&gt;x&lt;/b&gt;")
    end

    # A javascript: or data: URL in a note is either a mistake or an attack, and
    # either way it is text.
    it "refuses a link that is not http, and keeps what was written" do
      expect(helper.note_body("[click](javascript:alert(1))")).to eq("[click](javascript:alert(1))")
    end

    it "does not swallow the punctuation after a URL" do
      expect(helper.note_body("at https://example.com/a, then")).to include(">https://example.com/a</a>, then")
    end

    it "handles several links in one note" do
      html = helper.note_body("[one](https://a.test) and https://b.test and [two](https://c.test)")

      expect(html.scan("<a href").size).to eq(3)
    end

    it "is empty for an empty body" do
      expect(helper.note_body(nil)).to eq("")
    end
  end
end

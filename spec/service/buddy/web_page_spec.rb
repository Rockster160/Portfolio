require "rails_helper"

# Opening a link: what comes back, and what is refused before anything is
# fetched at all.
RSpec.describe Buddy::WebPage do
  # Every host in here is spelled publicly, so the guard's DNS lookup is the
  # one thing standing between the suite and a real resolver.
  before { allow(Resolv).to receive(:getaddresses).and_return(["93.184.216.34"]) }

  def stub_page(body, url: "https://example.com/events/yappy-hour/", type: "text/html; charset=UTF-8", status: 200)
    stub_request(:get, url).to_return(status: status, body: body, headers: { "Content-Type" => type })
  end

  # An events page that lists several dates under one title: the shape the URL
  # cannot answer, since its path names one date and the page names three.
  def events_html
    <<~HTML
      <html>
        <head>
          <title>Yappy Hour | Events</title>
          <meta name="description" content="A dog-friendly gathering in the park.">
          <script>var tracking = 1;</script>
        </head>
        <body>
          <nav><a href="/">Home</a><a href="/events">Events</a></nav>
          <main>
            <h1>Yappy Hour</h1>
            <p>Join Public Lands for a tail-wagging good time. #{"Bring your dog. " * 20}</p>
            <p>Date: June 11, 2026</p>
            <p>Time: 6:00 p.m. - 9:00 p.m.</p>
            <p>Location: Fairmont Park, 1040 E Sugarmont Dr</p>
            <p>Date: October 8</p>
            <p>Time: 6:00 p.m. - 9:00 p.m.</p>
            <p>Location: Jordan Park, 1060 S 900 W</p>
          </main>
          <footer>Copyright the city</footer>
        </body>
      </html>
    HTML
  end

  it "hands back the page's own text" do
    stub_page(events_html)

    page = described_class.read("https://example.com/events/yappy-hour/")

    expect(page[:title]).to eq("Yappy Hour | Events")
    expect(page[:description]).to eq("A dog-friendly gathering in the park.")
    expect(page[:text]).to include("Date: October 8")
    expect(page[:text]).to include("Location: Jordan Park, 1060 S 900 W")
  end

  # The date in the path is one of several the page lists, which is the whole
  # reason the page gets read rather than the URL.
  it "keeps every date the page lists rather than the one in the link" do
    stub_page(events_html)

    text = described_class.read("https://example.com/events/yappy-hour/")[:text]

    expect(text).to include("June 11, 2026")
    expect(text).to include("October 8")
  end

  it "leaves out the chrome that surrounds the page" do
    stub_page(events_html)

    text = described_class.read("https://example.com/events/yappy-hour/")[:text]

    expect(text).not_to include("var tracking")
    expect(text).not_to include("Copyright the city")
  end

  # A date, a time and a place written on three lines have to arrive on three
  # lines; run together they read as one sentence and the place loses its label.
  it "keeps the page's own line breaks" do
    stub_page(events_html)

    text = described_class.read("https://example.com/events/yappy-hour/")[:text]

    expect(text).to match(/Date: October 8\n+Time: 6:00 p\.m\./)
  end

  it "says which page it ended up on" do
    stub_request(:get, "https://example.com/short").to_return(
      status: 301, headers: { "Location" => "https://example.com/events/yappy-hour/" },
    )
    stub_page(events_html)

    expect(described_class.read("https://example.com/short")[:url])
      .to eq("https://example.com/events/yappy-hour/")
  end

  it "truncates a page too long to hand over whole" do
    stub_page("<html><body><p>#{"word " * 4_000}</p></body></html>")

    page = described_class.read("https://example.com/events/yappy-hour/")

    expect(page[:text].length).to be <= described_class::MAX_TEXT
    expect(page[:truncated]).to be(true)
  end

  it "reads a plain text page as it stands" do
    stub_page("Yappy Hour\nOctober 8, 6pm\n", type: "text/plain")

    expect(described_class.read("https://example.com/events/yappy-hour/")[:text])
      .to eq("Yappy Hour\nOctober 8, 6pm")
  end

  describe "what it won't open" do
    it "refuses anything that isn't an http link" do
      expect { described_class.read("file:///etc/passwd") }
        .to raise_error(/isn't a web link/)
    end

    it "refuses the loopback by name" do
      expect { described_class.read("http://localhost:8790/jobs/1488") }
        .to raise_error(/machine on the network/)
    end

    it "refuses a literal private address" do
      expect { described_class.read("http://192.168.1.4/admin") }
        .to raise_error(/machine on the network/)
    end

    # The address cloud metadata answers on, which is why a name resolving
    # there matters as much as one spelled that way.
    it "refuses a public name that resolves somewhere private" do
      allow(Resolv).to receive(:getaddresses).and_return(["169.254.169.254"])

      expect { described_class.read("https://metadata.example.com/") }
        .to raise_error(/machine on the network/)
    end

    # A redirect is a second URL chosen by someone else, so it is checked the
    # way the first one was.
    it "refuses a redirect that lands somewhere private" do
      stub_request(:get, "https://example.com/go").to_return(
        status: 302, headers: { "Location" => "http://127.0.0.1:3141/system" },
      )

      expect { described_class.read("https://example.com/go") }
        .to raise_error(/machine on the network/)
    end

    it "refuses a link carrying credentials" do
      expect { described_class.read("https://user:secret@example.com/") }
        .to raise_error(/username and password/)
    end

    it "says so when the page isn't there" do
      stub_page("Not found", status: 404)

      expect { described_class.read("https://example.com/events/yappy-hour/") }
        .to raise_error(/answered 404/)
    end

    it "says so when the link is a file rather than a page" do
      stub_page("%PDF-1.4", type: "application/pdf")

      expect { described_class.read("https://example.com/events/yappy-hour/") }
        .to raise_error(%r{application/pdf})
    end

    it "says so when the host can't be reached" do
      stub_request(:get, "https://example.com/events/yappy-hour/").to_timeout

      expect { described_class.read("https://example.com/events/yappy-hour/") }
        .to raise_error(/couldn't reach example.com/)
    end

    it "gives up on a redirect loop" do
      stub_request(:get, "https://example.com/loop").to_return(
        status: 302, headers: { "Location" => "https://example.com/loop" },
      )

      expect { described_class.read("https://example.com/loop") }
        .to raise_error(/keeps redirecting/)
    end
  end
end

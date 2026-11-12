require "rails_helper"

RSpec.describe RubyHighlight do
  def text_of(segments)
    segments.map { |segment| CGI.unescapeHTML(segment.html.gsub(/<[^>]+>/, "")) }
  end

  let(:code) {
    <<~RUBY
      user = User.me
      CODE = <<~'JIL'.strip
        done = Buddy.yell("key", "hi", {})::Boolean
      JIL
      puts "ok"
    RUBY
  }

  it "draws each heredoc body as a block of its own, between the code around it" do
    segments = described_class.segments(code)

    expect(segments.map(&:kind)).to eq([:code, :heredoc, :code])
    expect(text_of(segments)).to eq([
      "user = User.me\nCODE = <<~'JIL'.strip",
      "  done = Buddy.yell(\"key\", \"hi\", {})::Boolean",
      "JIL\nputs \"ok\"",
    ])
  end

  it "checks a JIL heredoc and says when it passes" do
    heredoc = described_class.segments(code)[1]

    expect(heredoc).to be_jil
    expect(heredoc).to be_valid
    expect(heredoc.html).to include(%(<span class="rh-const">Buddy</span>))
    expect(heredoc.html).to include(%(<span class="rh-cast">::Boolean</span>))
  end

  it "marks a JIL heredoc that doesn't validate, with why" do
    broken = code.sub("Buddy.yell", "Buddy.noSuchMethod")

    heredoc = described_class.segments(broken)[1]

    expect(heredoc).not_to be_valid
    expect(heredoc.error).to be_present
  end

  it "keeps two heredocs opened on one line apart, in order, and leaves other heredocs unchecked" do
    two = <<~'RUBY'
      run(<<~A, <<~B)
        first #{name}
      A
        second
      B
    RUBY

    segments = described_class.segments(two)

    expect(segments.map(&:kind)).to eq([:code, :heredoc, :code, :heredoc, :code])
    expect(text_of(segments)).to eq(["run(<<~A, <<~B)", "  first \#{name}", "A", "  second", "B"])
    expect(segments.select(&:heredoc?)).to all(have_attributes(jil: false))
  end

  it "colors Ruby the way the editor does" do
    html = described_class.segments(%(def go(x) = raise(:nope, 2, nil) # why\n)).first.html

    expect(html).to include(%(<span class="rh-kw">def</span>))
    expect(html).to include(%(<span class="rh-def">go</span>))
    expect(html).to include(%(<span class="rh-special">raise</span>))
    expect(html).to include(%(<span class="rh-symbol">:</span><span class="rh-symbol">nope</span>))
    expect(html).to include(%(<span class="rh-num">2</span>))
    expect(html).to include(%(<span class="rh-nil">nil</span>))
    expect(html).to end_with(%(<span class="rh-comment"># why</span>))
  end

  it "escapes what it draws" do
    expect(described_class.segments(%(x = "<b>"\n)).first.html).not_to include("<b>")
  end
end

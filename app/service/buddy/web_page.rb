require "ipaddr"
require "resolv"

module Buddy
  # Opening a link and handing back what the page actually says.
  #
  # A link that arrives in a message is a fact nobody has read. Its slug
  # carries a name and often a date, and both are guesses about the page: one
  # page can list three dates under one title, and the date in the path need
  # not be any of them. So this fetches the page and extracts its text, and
  # what comes back is what a person would see if they opened it.
  #
  # Everything that can go wrong comes back as a raise carrying a sentence
  # about the LINK rather than about the plumbing, because the caller is a tool
  # whose failures are read out loud.
  module WebPage
    module_function

    # The model is waiting on this inside a turn, so it is a short fuse - long
    # enough for a slow municipal site, short enough to stay a turn.
    TIMEOUT = 10

    # Read off the wire at most. Past this it is a download rather than a page,
    # and parsing it would cost more than any answer in it is worth.
    MAX_BYTES = 2_000_000

    # How much text the model is handed. A page says what it is near the top;
    # the tail of a long one is navigation, comments and boilerplate.
    MAX_TEXT = 6_000

    # Redirects are followed by hand rather than by HTTParty, so that every hop
    # is checked the way the first URL was. A redirect is a second URL chosen
    # by someone else, and a guard that only sees the first one is no guard.
    MAX_HOPS = 4

    # Only what is readable as prose. A PDF or an image is not refused because
    # it is dangerous but because nothing here can turn it into words, and
    # saying so is a better answer than a page of mojibake.
    READABLE_TYPES = %w[text/html application/xhtml+xml text/plain text/xml].freeze

    # Chrome, nearly everywhere, and never the thing being asked about. Dropped
    # before the text is taken so a menu of forty links doesn't fill the budget
    # that the article was supposed to get.
    DROP_NODES = "script, style, noscript, svg, iframe, nav, header, " \
                 "footer, aside, form, button, template".freeze

    # Elements whose close is a line break. Without this every paragraph,
    # heading and table cell runs into the next one, and a page that lists a
    # date, a time and a place on three lines arrives as one sentence.
    BLOCK_TAGS = "p|div|li|h1|h2|h3|h4|h5|h6|tr|td|th|section|article|main|" \
                 "blockquote|dd|dt|figcaption|pre".freeze

    # Prefer `main`/`article` over the whole body only when there is really
    # something in it. Plenty of pages open a `main` and then put the content
    # beside it.
    MAIN_MIN = 400

    # Networks a request from this app has no business reaching: the loopback,
    # the private ranges, the link-local block that cloud metadata lives on,
    # and the rest of the reserved space. A link can arrive from anywhere - a
    # person pastes it, or it comes out of an email - so the host is checked
    # against where it actually RESOLVES rather than against how it is spelled.
    RESERVED = %w[
      0.0.0.0/8
      10.0.0.0/8
      100.64.0.0/10
      127.0.0.0/8
      169.254.0.0/16
      172.16.0.0/12
      192.0.0.0/24
      192.168.0.0/16
      198.18.0.0/15
      224.0.0.0/4
      ::/128
      ::1/128
      fc00::/7
      fe80::/10
      ff00::/8
    ].map { |cidr| IPAddr.new(cidr) }.freeze

    # Hostnames that name a machine rather than a site, whatever they resolve
    # to - or don't. A name that resolves to nothing never reaches the IP check
    # at all, so these are refused by spelling as well.
    LOCAL_SUFFIXES = %w[.local .localhost .internal .home .lan].freeze

    USER_AGENT = "Mozilla/5.0 (compatible; ZygyBot/1.0; +https://ardesian.com)".freeze
    ACCEPT     = "text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.1".freeze

    # { url:, title:, description:, text:, truncated: } - `url` is where the
    # redirects ended up, which is the one worth quoting back.
    def read(url)
      uri, response = fetch_page(checked_uri(url))

      code = response.code.to_i
      raise "#{uri.host} answered #{code} for that link, so there's no page there" unless code == 200

      type = content_type(response)
      unless READABLE_TYPES.include?(type)
        raise "that link is #{type.presence || "not a page"}, which isn't something I can read"
      end

      body  = response.body.to_s.byteslice(0, MAX_BYTES).to_s
      parts = (type == "text/plain" ? { text: squeezed(body) } : page_parts(body))
      raise "#{uri.host} gave me a page with no readable text on it" if parts[:text].blank?

      {
        url:         uri.to_s,
        title:       parts[:title].presence,
        description: parts[:description].presence,
        text:        parts[:text].truncate(MAX_TEXT),
        truncated:   (true if parts[:text].length > MAX_TEXT),
      }.compact
    end

    # Each hop is re-checked, so a public host redirecting to a private address
    # is refused at the hop rather than followed.
    def fetch_page(uri)
      MAX_HOPS.times {
        response = get(uri)
        target   = (response.headers["location"].to_s if (300..399).cover?(response.code.to_i))
        return [uri, response] if target.blank?

        uri = checked_uri(URI.join(uri, target).to_s)
      }
      raise "#{uri.host} keeps redirecting, so there's no page to land on"
    end

    def get(uri)
      HTTParty.get(
        uri.to_s,
        headers:          { "User-Agent" => USER_AGENT, "Accept" => ACCEPT },
        timeout:          TIMEOUT,
        follow_redirects: false,
      )
    rescue StandardError => e
      raise "couldn't reach #{uri.host} (#{e.class.name.demodulize})"
    end

    def checked_uri(url)
      raw = url.to_s.strip
      uri = parsed(raw)
      raise "#{raw.truncate(60)} isn't a web link I can open" unless uri.is_a?(URI::HTTP) && uri.host.present?
      raise "that link carries a username and password in it, so I left it alone" if uri.userinfo.present?
      raise "#{uri.host} is a machine on the network rather than a site on the web" if private_host?(uri.host)

      uri
    end

    def parsed(raw)
      URI.parse(raw)
    rescue URI::InvalidURIError
      nil
    end

    def private_host?(host)
      name = host.downcase.delete_suffix(".")
      return true if name == "localhost" || LOCAL_SUFFIXES.any? { |s| name.end_with?(s) }

      addresses(name).any? { |addr| RESERVED.any? { |net| net.include?(addr) } }
    end

    # A literal address is checked as itself; a name is checked against every
    # address it answers with, since one of several is enough to be a problem.
    # A name that resolves to nothing comes back empty and is left to the fetch
    # to fail on - there is nothing to reach, so there is nothing to guard.
    def addresses(host)
      literal = address(host)
      return [literal] if literal

      Resolv.getaddresses(host).filter_map { |found| address(found) }
    rescue StandardError
      []
    end

    def address(value)
      IPAddr.new(value.to_s)
    rescue StandardError
      nil
    end

    def content_type(response)
      header = response.headers["content-type"].to_s
      header.split(";").first.to_s.downcase.strip
    end

    def page_parts(html)
      doc   = ::Nokogiri::HTML(html)
      title = doc.title.to_s.squish
      desc  = (meta(doc, "description") || meta(doc, "og:description")).to_s.squish
      doc.css(DROP_NODES).each(&:remove)

      { title: title, description: desc, text: text_of(main_node(doc)) }
    end

    def meta(doc, name)
      node = doc.at("meta[name='#{name}']") || doc.at("meta[property='#{name}']")
      node&.[]("content")
    end

    def main_node(doc)
      body = doc.at("body") || doc
      main = doc.at("main") || doc.at("article")
      main && main.text.to_s.length >= MAIN_MIN ? main : body
    end

    def text_of(node)
      html = node.to_html
      html = html.gsub(%r{</(#{BLOCK_TAGS})>}i, "\n")
      html = html.gsub(%r{<br\s*/?>}i, "\n")

      squeezed(::ActionView::Base.full_sanitizer.sanitize(html).to_s)
    end

    # Whatever the page was encoded in, the model reads UTF-8, and blank lines
    # are the only structure worth keeping once the markup is gone.
    def squeezed(text)
      out = text.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "")
      out = out.tr(" ", " ").tr("\t", " ")
      out = out.gsub(/ {2,}/, " ")
      out = out.gsub(/ *\n */, "\n")
      out = out.gsub(/\n{3,}/, "\n\n")
      out.strip
    end
  end
end

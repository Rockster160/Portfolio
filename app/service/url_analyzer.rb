class UrlAnalyzer
  MATCH_REGEX = /
    (?<origin>
      (?<site>
        (?:(?<protocol>(?<scheme>\w+):)\/\/)?
        (?<hostname>[^\/:\?\#]*)
      )
      (?::(?<port>\d{1,5}))?
    )
    (?<pathname>\/(?:[^\?\#]*)?\/(?<filename>[^\?]*))?
    (?<search>\?(?<query>[^\#]*))?
    (?<hash>\#(?<fragment>.*?$))?
  /x

  # def parse(url)
  #   path, query, fragment = *break_url(url)
  #
  #   {
  #     path: path,
  #     query: query.present? ? Rack::Utils.parse_nested_query(query) : nil,
  #     fragment: fragment,
  #   }.compact
  # end
  #
  # def path_param(url, key)
  # end

  def initialize(url)
    @url = url.strip
    @matchdata = url.match(MATCH_REGEX).named_captures.deep_symbolize_keys
  end

  def analyze
    @analyze ||= begin
      {
        origin:   @matchdata[:origin],
        site:     @matchdata[:site],
        protocol: @matchdata[:protocol],
        scheme:   @matchdata[:scheme],
        hostname: @matchdata[:hostname],
        port:     @matchdata[:port],
        subdomain: nil,
        domain:    nil,
        tld:       nil,
        pathname: @matchdata[:pathname],
        filename: @matchdata[:filename],
        search:   @matchdata[:search],
        query:    @matchdata[:query],
        hash:     @matchdata[:hash],
        fragment: @matchdata[:fragment],
      }.tap { |data| data.merge!([:subdomain, :domain, :tld].zip(break_domains).to_h) }
    end
  end

  def params
    ::Rack::Utils.parse_nested_query(analyze[:query])
  end

  def path_param(key)
    return unless analyze[:pathname].present?

    paths = analyze[:pathname][1..].split("/")
    idx = paths.index(key.to_s)
    return unless (0...paths.length).cover?(idx)

    paths[idx+1]
  end

  private

  def break_domains
    # subd, domain, tld
    ds = @matchdata[:hostname].split(".")
    return [nil, *ds] if ds.length <= 2
    # at least 3...

    end_tlds = ds[-2..].any? { |d| d.length <= 2 } ? ds[-2..] : ds[-1..]
    *subds, domain = *(ds - end_tlds)

    [subds.join(".").presence, domain, end_tlds.join(".").presence]
  end
end

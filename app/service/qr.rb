class Qr
  attr_accessor :qr

  def self.wifi(ssid, pass)
    filename = Digest::SHA1.hexdigest("#{ssid}:#{pass}") + ".png"

    FileStorage.get_or_upload(filename) do
      new("WIFI:S:#{ssid};T:WPA;P:#{pass};;").to_io
    end
  end

  def initialize(str, opts={})
    @qr = ::RQRCode::QRCode.new(str, opts)
    # {
    #   size: 2,
    #   level: :l,
    #   mode: :byte_8bit
    # }
  end

  def to_html
    # <img src="data:image/png;base64,<%= qr.as_png.to_s %>" />
  end

  def to_svg
    @qr.as_svg(
      color: "000",
      shape_rendering: "crispEdges",
      module_size: 11,
      standalone: true,
      use_path: true
    )
  end

  def to_bi
    @qr.as_png.to_s
  end

  def to_io
    StringIO.new(@qr.as_png(size: 120).to_s)
  end

  def to_s
    to_bi
  end
end

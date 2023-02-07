class Qr
  attr_accessor :qr

  def self.wifi(ssid, pass)
    filename = Digest::SHA1.hexdigest("#{ssid}:#{pass}") + ".svg"
    FileStorage.soft_get(filename)&.tap { |f| return f.presigned_url(:get, expires_in: 1.hour.to_i) }

    qr = new("WIFI:S:#{ssid};T:WPA;P:#{pass};;")
    FileStorage.upload(qr.to_svg, filename: filename).presigned_url(:get, expires_in: 1.hour.to_i)
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
    # <img src="data:image/png;base64,<%= qr.to_png.to_s %>" />
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

  def to_s
    to_bi
  end
end

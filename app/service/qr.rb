# frozen_string_literal: true

# puts Qr.to_s("rdjn.me/lll", light: "\e[100m  \e[0m", dark: "\e[0m  ", level: :l)
# puts Qr.to_svg("rdjn.me/lll", level: :l)
# File.open("qr.png", "wb") { |f| f.write(Qr.to_io("rdjn.me/lll", level: :l, size: 21).read) }
# File.open("qr.png", "wb") { |f| f.write Qr.to_png("rdjn.me/lll", level: :l, size: 21) }

class Qr
  attr_accessor :qr

  def self.wifi(ssid, pass)
    filename = Digest::SHA1.hexdigest("#{ssid}:#{pass}") + ".png"

    FileStorage.get_or_upload(filename) {
      new("WIFI:S:#{ssid};T:WPA;P:#{pass};;").to_io(size: 600)
    }
  end

  def self.to_a(str, opts={}) = new(str, opts).to_a(opts)
  def self.to_s(str, opts={}) = new(str, opts).to_s(opts)
  def self.to_io(str, opts={}) = new(str, opts).to_io(opts)
  def self.to_svg(str, opts={}) = new(str, opts).to_svg(opts)
  def self.to_png(str, opts={}) = new(str, opts).to_png(opts)

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

  def to_svg(opts={})
    @qr.as_svg({
      color:           "000",
      shape_rendering: "crispEdges",
      module_size:     1,
      standalone:      true,
      use_path:        true,
    }.merge(opts))
  end

  def to_png(opts={})
    @qr.as_png(opts).to_s
  end

  def to_io(opts={})
    StringIO.new(@qr.as_png(opts).to_s)
  end

  def to_a(opts={})
    opts = { dark: 0, light: 1 }.merge(opts)

    @qr.to_s(dark: "0", light: "1").split("\n").map(&:chars).map { |line|
      line.map { |c| c == "0" ? opts[:dark] : opts[:light] }
    }
  end

  def to_s(opts={})
    opts = { dark: "x", light: " " }.merge(opts)
    @qr.to_s(opts)
  end
end

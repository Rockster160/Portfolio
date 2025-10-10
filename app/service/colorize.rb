module Colorize
  module_function

  def colorize(str, color, _opts={})
    "#{color_code(color)}#{str}#{reset_code}"
  end

  def reset_code(ground=:fg)
    "\e[#{ground == :bg ? 49 : 39};2;0m"
  end

  # def bold(text="")
  #   "\e[1m#{text}"
  # end

  def color_code(paint)
    case paint.length == 1 ? paint.first : paint
    when Array
      rgb_to_code(paint) if paint.length == 3
    when String, Symbol
      rgb_to_code(color_list[paint.to_s.to_sym] || hex_to_rgb(paint.to_s))
    end
  end

  def rgb_to_code(rgb)
    return if rgb.blank?

    r, g, b = *rgb
    "\e[38;2;#{r};#{g};#{b}m"
  end

  def hex_to_rgb(hex)
    hex_without_hash = hex.gsub("#", "")
    if hex_without_hash.length == 6
      return hex_without_hash.scan(/.{2}/).map { |rgb| rgb.to_i(16) }
    elsif hex_without_hash.length == 3
      return hex_without_hash.chars.map { |rgb| "#{rgb}#{rgb}".to_i(16) }
    else
      return nil
    end
  end

  def rgb(*arr)
    arr
  end

  def random(from_list: true)
    return color_list.values.sample if from_list

    rgb(rand(0..255), rand(0..255), rand(0..255))
  end

  # Helper

  def color_list
    {
      black:   rgb(0, 0, 0),
      white:   rgb(255, 255, 255),
      lime:    rgb(0, 255, 0),
      red:     rgb(255, 0, 0),
      blue:    rgb(0, 0, 255),
      yellow:  rgb(255, 255, 0),
      cyan:    rgb(0, 255, 255),
      magenta: rgb(255, 0, 255),
      gold:    rgb(218, 165, 32),
      silver:  rgb(192, 192, 192),
      grey:    rgb(150, 150, 150),
      maroon:  rgb(128, 0, 0),
      olive:   rgb(128, 128, 0),
      green:   rgb(0, 128, 0),
      purple:  rgb(128, 0, 128),
      teal:    rgb(0, 128, 128),
      navy:    rgb(0, 0, 128),
      rocco:   rgb(1, 96, 255),
      orange:  rgb(255, 150, 0),
      pink:    rgb(255, 150, 150),
    }
  end

  color_list.each_key do |color_key|
    Colorize.define_singleton_method(color_key) do |str|
      Colorize.color(color_key, str, reset: true)
    end
  end
end

class String
  def colorize(color)
    Colorize.colorize(self, color)
  end

  def uncolor
    gsub(/\e\[.*?m/, "")
  end
end

# Quick helper method so that colors show their pigment preview
def rgb(*arr)
  arr
end

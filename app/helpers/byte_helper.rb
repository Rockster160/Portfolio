module ByteHelper
  # Compact form of an absolute filesystem path — swaps `/Users/zoro`
  # (or whatever the current runtime user's home is) for `~`. Used by the
  # pwd bar so the drawer / header stays tight even for deep paths.
  def short_home(path)
    return "" if path.blank?

    home = ENV["HOME"].to_s
    return path if home.empty?
    path.start_with?(home) ? path.sub(home, "~") : path
  end
end

# https://github.com/flori/json/issues/399#issuecomment-734863279
# Fix for chatty warning:
# json/common.rb:155: warning: Using the last argument as keyword parameters is deprecated

module JSON
  module_function

  def parse(source, opts={})
    Parser.new(source, **opts).parse
  end
end

require "json"
require "open3"

# Real JS modules, run in node, ONCE per suite run.
#
# `output` is for the `spec/javascript/*_runner.js` files: each takes no input,
# imports the real module, exercises every case its spec has an opinion about,
# and prints one JSON blob. So the answer is the same for every example that
# reads it — but held in a `let` it was recomputed for each one, and
# spec/javascript spent most of its time starting node. byte_markdown alone
# spawned it forty-nine times to read the same forty-nine keys.
#
# `eval_module` is for the specs that hand the module their own input. Memoized
# on the script itself, so a spec that asks the same question in seven examples
# asks node once.
#
# Both hand back a frozen structure, all the way down: one shared answer read
# by many examples is only safe if none of them can write to it.
module JsRunner
  def self.output(relative_path, symbolize: false)
    @outputs ||= {}
    @outputs[[relative_path, symbolize]] ||= begin
      stdout, stderr, status = Open3.capture3("node", Rails.root.join(relative_path).to_s)
      raise "#{relative_path} failed: #{stderr}" unless status.success?

      deep_freeze(JSON.parse(stdout, symbolize_names: symbolize))
    end
  end

  def self.eval_module(script, symbolize: false)
    @evals ||= {}
    @evals[[script, symbolize]] ||= begin
      stdout, stderr, status = Open3.capture3("node", "--input-type=module", stdin_data: script)
      raise "node failed: #{stderr}" unless status.success?

      deep_freeze(JSON.parse(stdout, symbolize_names: symbolize))
    end
  end

  def self.deep_freeze(value)
    case value
    when ::Hash  then value.each_value { |v| deep_freeze(v) }
    when ::Array then value.each { |v| deep_freeze(v) }
    end
    value.freeze
  end
end

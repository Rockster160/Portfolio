require "json"
require "open3"

# The compiled Byte stylesheet, compiled ONCE for the whole suite run.
#
# The three specs that read it are each asserting a property of the whole
# cascade rather than of any one declaration, so they need the real compiled
# output. What they don't need is their own copy of it: a `let` re-runs per
# example, and at roughly half a second a compile that was fifteen subprocesses
# for one file — more wall clock than every other spec in spec/assets put
# together.
#
# Frozen, because one shared copy read by three files is only safe if none of
# them can write to it.
module CompiledCss
  RUNNER = "spec/assets/byte_css_runner.rb".freeze

  def self.rules
    @rules ||= begin
      stdout, stderr, status = Open3.capture3(
        "bundle", "exec", "ruby", Rails.root.join(RUNNER).to_s, chdir: Rails.root.to_s
      )
      raise "#{RUNNER} failed: #{stderr}" unless status.success?

      JSON.parse(stdout).each(&:freeze).freeze
    end
  end

  # Every rule that sets a font-size, which is the only kind the scaling spec
  # has an opinion about.
  def self.sized
    @sized ||= rules.select { |rule| rule["font_size"].present? }.freeze
  end
end

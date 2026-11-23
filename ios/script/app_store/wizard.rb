require "io/console"
require "time"

module AppStore
  # What the scripts say and ask. A step only a person can take opens its page in
  # the browser, lists what to do there, and waits for Enter; o opens it again.
  module Wizard
    module_function

    def title(text)
      puts
      puts bold(text)
    end

    def step(text)
      puts
      puts bold("== #{text}")
    end

    def say(text) = puts("   #{text}")
    def done(text) = puts("   #{green("✓")} #{text}")
    def warn(text) = puts("   #{yellow("!")} #{text}")

    # steps: what to do, numbered when there are several. page: [what the site is, url].
    def pause(steps, page: nil)
      steps = Array(steps)
      puts
      if page
        where, url = page
        puts("   #{bold("Opening #{where} in your browser:")}")
        puts("   #{url}")
        open_page(url)
        puts
      end
      steps.each_with_index { |text, index|
        lead = steps.size > 1 ? "#{index + 1}." : "›"
        text.each_line.with_index { |line, row|
          puts("   #{yellow(row.zero? ? lead : " " * lead.size)} #{line.chomp}")
        }
      }
      loop do
        print("   Enter when done#{" (o, Enter opens the page again)" if page}: ")
        break unless read_line.casecmp?("o") && page

        open_page(page.last)
      end
    end

    def open_page(url)
      system("open", url) if $stdout.tty?
    end

    # The answer, or the default on a bare Enter. required: false allows nothing.
    def ask(question, default: nil, required: true, secret: false)
      shown = secret && default ? "saved" : default
      loop do
        print("   #{question}#{" [#{shown}]" unless shown.to_s.empty?}: ")
        answer = secret ? read_secret : read_line
        answer = default.to_s if answer.empty?
        return answer unless answer.empty? && required
      end
    end

    def yes?(question, default: true)
      loop do
        print("   #{question} #{default ? "[Y/n]" : "[y/N]"}: ")
        answer = read_line.downcase
        return default if answer.empty?
        return true if %w[y yes].include?(answer)
        return false if %w[n no].include?(answer)
      end
    end

    # options: [[label, value]]; the default is the value picked on a bare Enter.
    def choose(question, options, default: options.first.last)
      puts("   #{question}")
      options.each_with_index { |(label, value), index|
        puts("     #{index + 1}. #{label}#{" (default)" if value == default}")
      }
      loop do
        print("   Pick 1 to #{options.size}: ")
        answer = read_line
        return default if answer.empty?

        picked = options[answer.to_i - 1] if answer.match?(/\A\d+\z/) && answer.to_i.positive?
        return picked.last if picked
      end
    end

    # "12 minutes ago" from an App Store Connect time.
    def ago(time)
      minutes = ((Time.now - Time.parse(time)) / 60).round
      return "#{minutes} minutes ago" if minutes < 120
      return "#{minutes / 60} hours ago" if minutes < 48 * 60

      "#{minutes / 1440} days ago"
    end

    def read_line
      line = $stdin.gets
      raise Interrupt if line.nil?

      line.strip
    end

    def read_secret
      line = $stdin.tty? ? $stdin.noecho(&:gets) : $stdin.gets
      puts
      raise Interrupt if line.nil?

      line.strip
    end

    def bold(text) = paint(text, 1)
    def green(text) = paint(text, 32)
    def yellow(text) = paint(text, 33)
    def paint(text, code) = $stdout.tty? ? "\e[#{code}m#{text}\e[0m" : text
  end
end

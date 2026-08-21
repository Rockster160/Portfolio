require "rails_helper"

RSpec.describe "chase alert text extraction" do
  SP = "/private/tmp/claude-501/-Users-zoro-code-Portfolio/bc157c22-b018-42a6-a785-095ae0b994c4/scratchpad".freeze

  def text_for(file)
    Emails::ParseMail.call(Mail.new(File.read("#{SP}/#{file}"))).text_part
  end

  %w[venmo chasecrd tmobile jpmc].each do |name|
    it "dumps #{name}" do
      puts "===== #{name.upcase} ====="
      puts text_for("#{name}.eml").split("You are receiving").first.inspect
    end
  end
end

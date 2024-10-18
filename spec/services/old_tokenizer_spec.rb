RSpec.describe OldTokenizer do
  context "when modifying a str" do
    it "can protect anything in the regex" do
      original = "hello, world! (hello, world!) *special* things {*special* protected}"

      changed = OldTokenizer.protect(original, /\([^\)]*\)/, /\{[^\}]*\}/) do |str|
        str.gsub!(/hello|special/, "blahblah")
        str.gsub!(/\*/, ":")
      end

      expect(original).to eq("hello, world! (hello, world!) *special* things {*special* protected}")
      expect(changed).to eq("blahblah, world! (hello, world!) :blahblah: things {*special* protected}")
    end
  end
end

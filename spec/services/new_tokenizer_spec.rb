RSpec.describe NewTokenizer do
  describe "tokenizer" do
    it "should map the tokens" do
      {
        'This is a (((simple))) example.': {
          "||TOKEN1||": "(simple)", "||TOKEN2||": "(||TOKEN1||)", "||TOKEN3||": "(||TOKEN2||)",
        },
        'This is a (com(plex) example).': {
          "||TOKEN1||": "(plex)", "||TOKEN2||": "(com||TOKEN1|| example)",
        },
        '(This) [is] {just} "a" _bunch_ /of/ *separate* ((styles))': {
          "||TOKEN1||": "\"a\"", "||TOKEN2||": "(This)", "||TOKEN3||": "[is]", "||TOKEN4||": "{just}",
          "||TOKEN5||": "/of/", "||TOKEN6||": "(styles)", "||TOKEN7||": "(||TOKEN6||)",
        },
        '"This is (all {quoted, so nothing\' } gets [tokenized]"': {
          "||TOKEN1||": "\"This is (all {quoted, so nothing' } gets [tokenized]\""
        },
        'With " (unclosed)': {
          "||TOKEN1||": "(unclosed)"
        },
        '(Full parens)': {
          "||TOKEN1||": "(Full parens)"
        },
        'Unmatched (section {without a close" } test [ok]': {
          "||TOKEN1||": "{without a close\" }", "||TOKEN2||": "[ok]"
        },
        'This is a test { with (nested [sections]) } and "ignore {these}"': {
          "||TOKEN1||": "\"ignore {these}\"", "||TOKEN2||": "[sections]",
          "||TOKEN3||": "(nested ||TOKEN2||)", "||TOKEN4||": "{ with ||TOKEN3|| }"
        },
        'Escaped brackets \\{should not be tokenized} and normal brackets {this should}': {
          "||TOKEN1||": "{this should}"
        },
      }.each do |text, tokens|
        tz = NewTokenizer.new(text.to_s)
        expect(tz.tokens).to match_hash(tokens)
      end
    end
  end
end

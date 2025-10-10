RSpec.describe Tokenizer do
  describe "tokenize" do
    it "maps the tokens" do
      {
        "This is a (((simple))) example.":                                                {
          __TOKEN1__: "(simple)", __TOKEN2__: "(__TOKEN1__)", __TOKEN3__: "(__TOKEN2__)"
        },
        "This is a (com(plex) example).":                                                 {
          __TOKEN1__: "(plex)", __TOKEN2__: "(com__TOKEN1__ example)"
        },
        '(This) [is] {just} "a" _bunch_ /of/ *separate* ((styles))':                      {
          __TOKEN1__: "\"a\"",
          __TOKEN2__: "(This)",
          __TOKEN3__: "[is]",
          __TOKEN4__: "{just}",
          __TOKEN5__: "/of/",
          __TOKEN6__: "(styles)",
          __TOKEN7__: "(__TOKEN6__)",
        },
        '"This is (all {quoted, so nothing\' } gets [tokenized]"':                        {
          __TOKEN1__: "\"This is (all {quoted, so nothing' } gets [tokenized]\"",
        },
        'With " (unclosed)':                                                              {
          __TOKEN1__: "(unclosed)",
        },
        "(Full parens)":                                                                  {
          __TOKEN1__: "(Full parens)",
        },
        'Unmatched (section {without a close" } test [ok]':                               {
          __TOKEN1__: "{without a close\" }", __TOKEN2__: "[ok]"
        },
        'This is a test { with (nested [sections]) } and "ignore {these}"':               {
          __TOKEN1__: "\"ignore {these}\"",
          __TOKEN2__: "[sections]",
          __TOKEN3__: "(nested __TOKEN2__)",
          __TOKEN4__: "{ with __TOKEN3__ }",
        },
        "Escaped brackets \\{should not be tokenized} and normal brackets {this should}": {
          __TOKEN1__: "{this should}",
        },
      }.each do |text, tokens|
        tz = Tokenizer.new(text.to_s)
        expect(tz.tokens).to match_hash(tokens)
      end
    end
  end
end

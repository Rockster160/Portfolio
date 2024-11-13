import { genHex } from "./form_helpers.js"

export default class Tokenizer {
  static WRAP_PAIRS = {
    "(": ")",
    "[": "]",
    "{": "}",
    "\"": "\"",
    "/": "/"
  };

  constructor(text, extraPairs = {}, only = null) {
    this.pairs = only === null ? { ...Tokenizer.WRAP_PAIRS, ...extraPairs } : only;
    this.tokens = {};
    this.tokenCount = 0;

    this.text = this.tokenizeQuotes(text);
    const result = this.tokenize();
    this.tokenizedText = result[0];
  }

  static split(text, { untokenize = true, unwrap = false, by = " " } = {}) {
    const tz = new Tokenizer(text);
    return tz.tokenizedText.split(by).map(str =>
      untokenize ? tz.untokenize(str, { unwrap }) : str
    );
  }

  untokenize(str = null, { levels = null, unwrap = false } = {}, callback = null) {
    let untokenized = (str || this.tokenizedText).slice();
    let i = 0;

    while (true) {
      if ((levels !== null && i >= levels) || i > untokenized.length) {
        break
      };

      let replaced = false
      Object.entries(this.tokens).forEach(([token, txt]) => {
        const regex = new RegExp(token.replace(/[-\/\\^$*+?.()|[\]{}]/g, '\\$&'), "g");
        untokenized = untokenized.replaceAll(regex, (a) => {
          replaced = true
          const val = unwrap ? txt.slice(1, -1) : txt;
          return callback ? callback(val) : val;
        });
      });

      if (!replaced) { break };

      i += 1;
    }
    return untokenized;
  }

  tokenizeQuotes(str) {
    let tokenized = str.slice();
    // if (tokenized[0] === "\"" && tokenized[tokenized.length-1] === "\"") {
    //   // Have not added this to RB
    //   const fullToken = this.generateToken();
    //   this.tokens[fullToken] = tokenized;
    //   return fullToken
    // }

    while (true) {
      const firstIdx = this.findIndex(tokenized, "\"");
      if (firstIdx === null) { break }

      const nextIdx = this.findIndex(tokenized, "\"", firstIdx);
      if (nextIdx === null) { break }

      const quoted = tokenized.slice(firstIdx, nextIdx + 1);
      const token = this.generateToken();
      tokenized = tokenized.slice(0, firstIdx) + token + tokenized.slice(nextIdx + 1);
      this.tokens[token] = quoted;
    }

    return tokenized;
  }

  findIndex(str, char, after = -1) {
    const regex = new RegExp(`[${char.replace(/[-\/\\^$*+?.()|[\]{}]/g, '\\$&')}]`, 'g');
    let match;
    while ((match = regex.exec(str)) !== null) {
      const idx = match.index;
      if (idx > after) {
        const escapes = str.slice(0, idx).match(/\\*$/)[0].length;
        if (escapes % 2 === 0) {
          return idx;
        }
      }
    }
    return null;
  }

  tokenize(untilChar = null, idx = 0, nest = 0) {
    let buffer = "";

    while (true) {
      if (idx >= this.text.length) {
        if (untilChar === null) {
          return [buffer, idx]
          // return
        }
        break;
      }

      const char = this.text[idx];
      const nextEscaped = char === "\\" && idx < this.text.length && this.text.slice(0, idx + 1).match(/\\*$/)[0].length % 2 === 1;

      if (nextEscaped) {
        buffer += "\\" + this.text[idx + 1];
        idx += 1;
      } else if (char === untilChar) {
        buffer += char;
        break;
      } else if (this.pairs[char]) {
        const nextIdx = this.findIndex(this.text, this.pairs[char], idx);
        if (nextIdx === null) {
          buffer += char;
        } else {
          const result = this.tokenize(this.pairs[char], idx + 1, nest + 1);
          if (result === undefined) {
            buffer += char;
          } else {
            const [wrapped, next] = result;
            idx = next;
            const token = this.generateToken();
            buffer += token;
            this.tokens[token] = char + wrapped;
          }
        }
      } else {
        buffer += char;
      }

      idx += 1;
    }

    return [buffer, idx];
  }

  generateToken() {
    this.tokenCount += 1;
    return `__TOKEN${this.tokenCount}__`;
  }
}

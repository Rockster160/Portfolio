var a_W2N, n_W2N, g_W2N,
    W2NStandardWords = {
      'zero': 0,
      'one': 1,
      'two': 2,
      'three': 3,
      'four': 4,
      'five': 5,
      'six': 6,
      'seven': 7,
      'eight': 8,
      'nine': 9,
      'ten': 10,
      'eleven': 11,
      'twelve': 12,
      'thirteen': 13,
      'fourteen': 14,
      'fifteen': 15,
      'sixteen': 16,
      'seventeen': 17,
      'eighteen': 18,
      'nineteen': 19,
      'twenty': 20,
      'thirty': 30,
      'forty': 40,
      'fifty': 50,
      'sixty': 60,
      'seventy': 70,
      'eighty': 80,
      'ninety': 90
    },
    W2NMagnitudeWords = {
      'thousand':     1000,
      'million':      1000000,
      'billion':      1000000000,
      'trillion':     1000000000000,
      'quadrillion':  1000000000000000,
      'quintillion':  1000000000000000000,
      'sextillion':   1000000000000000000000,
      'septillion':   1000000000000000000000000,
      'octillion':    1000000000000000000000000000,
      'nonillion':    1000000000000000000000000000000,
      'decillion':    1000000000000000000000000000000000,
    };
var W2N = {
  text2num: function(s) {
    a_W2N = s.toString().split(/[\s-]+/);
    n_W2N = 0;
    g_W2N = 0;
    a_W2N.forEach(this.feach);
    return n_W2N + g_W2N;
  },
  feach: function(w) {
    var x = W2NStandardWords[w];
    if (x != null) {
      g_W2N = g_W2N + x;
    } else if (w == "hundred") {
      g_W2N = g_W2N * 100;
    } else {
      x = W2NMagnitudeWords[w];
      if (x != null) {
        n_W2N = n_W2N + g_W2N * x
        g_W2N = 0;
      } else {
        console.log("Unknown number: " + w);
      }
    }
  },
  wordToNumber: function(word) {
    if (word.toString() == parseInt(word).toString()) {
      return parseInt(word);
    } else {
      return this.text2num(word);
    }
  }
}

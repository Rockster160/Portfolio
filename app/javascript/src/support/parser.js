/*export*/ var TEOF = 'TEOF';
/*export*/ var TOP = 'TOP';
/*export*/ var TNUMBER = 'TNUMBER';
/*export*/ var TSTRING = 'TSTRING';
/*export*/ var TPAREN = 'TPAREN';
/*export*/ var TCOMMA = 'TCOMMA';
/*export*/ var TNAME = 'TNAME';

/*export*/ function Token(type, value, index) {
  this.type = type;
  this.value = value;
  this.index = index;
}

Token.prototype.toString = function () {
  return this.type + ': ' + this.value;
};



/*export*/ var INUMBER = 'INUMBER';
/*export*/ var IOP1 = 'IOP1';
/*export*/ var IOP2 = 'IOP2';
/*export*/ var IOP3 = 'IOP3';
/*export*/ var IVAR = 'IVAR';
/*export*/ var IFUNCALL = 'IFUNCALL';
/*export*/ var IEXPR = 'IEXPR';
/*export*/ var IMEMBER = 'IMEMBER';

/*export*/ function Instruction(type, value) {
  this.type = type;
  this.value = (value !== undefined && value !== null) ? value : 0;
}

Instruction.prototype.toString = function () {
  switch (this.type) {
    case INUMBER:
    case IOP1:
    case IOP2:
    case IOP3:
    case IVAR:
      return this.value;
    case IFUNCALL:
      return 'CALL ' + this.value;
    case IMEMBER:
      return '.' + this.value;
    default:
      return 'Invalid Instruction';
  }
};

var unaryInstructionCache = {};
/*export*/ function unaryInstruction(value) {
  var inst = unaryInstructionCache[value];
  if (!inst) {
    inst = unaryInstructionCache[value] = new Instruction(IOP1, value);
  }
  return inst;
}

var binaryInstructionCache = {};
/*export*/ function binaryInstruction(value) {
  var inst = binaryInstructionCache[value];
  if (!inst) {
    inst = binaryInstructionCache[value] = new Instruction(IOP2, value);
  }
  return inst;
}

var ternaryInstructionCache = {};
/*export*/ function ternaryInstruction(value) {
  var inst = ternaryInstructionCache[value];
  if (!inst) {
    inst = ternaryInstructionCache[value] = new Instruction(IOP3, value);
  }
  return inst;
}



/*export default*/ function contains(array, obj) {
  for (var i = 0; i < array.length; i++) {
    if (array[i] === obj) {
      return true;
    }
  }
  return false;
}




// import { Instruction, INUMBER, IOP1, IOP2, IOP3, IVAR, IEXPR, IMEMBER } from './instruction';

/*export default*/ function simplify(tokens, unaryOps, binaryOps, ternaryOps, values) {
  var nstack = [];
  var newexpression = [];
  var n1, n2, n3;
  var f;
  for (var i = 0; i < tokens.length; i++) {
    var item = tokens[i];
    var type = item.type;
    if (type === INUMBER) {
      nstack.push(item);
    } else if (type === IVAR && values.hasOwnProperty(item.value)) {
      item = new Instruction(INUMBER, values[item.value]);
      nstack.push(item);
    } else if (type === IOP2 && nstack.length > 1) {
      n2 = nstack.pop();
      n1 = nstack.pop();
      f = binaryOps[item.value];
      item = new Instruction(INUMBER, f(n1.value, n2.value));
      nstack.push(item);
    } else if (type === IOP3 && nstack.length > 2) {
      n3 = nstack.pop();
      n2 = nstack.pop();
      n1 = nstack.pop();
      if (item.value === '?') {
        nstack.push(n1.value ? n2.value : n3.value);
      } else {
        f = ternaryOps[item.value];
        item = new Instruction(INUMBER, f(n1.value, n2.value, n3.value));
        nstack.push(item);
      }
    } else if (type === IOP1 && nstack.length > 0) {
      n1 = nstack.pop();
      f = unaryOps[item.value];
      item = new Instruction(INUMBER, f(n1.value));
      nstack.push(item);
    } else if (type === IEXPR) {
      while (nstack.length > 0) {
        newexpression.push(nstack.shift());
      }
      newexpression.push(new Instruction(IEXPR, simplify(item.value, unaryOps, binaryOps, ternaryOps, values)));
    } else if (type === IMEMBER && nstack.length > 0) {
      n1 = nstack.pop();
      nstack.push(new Instruction(INUMBER, n1.value[item.value]));
    } else {
      while (nstack.length > 0) {
        newexpression.push(nstack.shift());
      }
      newexpression.push(item);
    }
  }
  while (nstack.length > 0) {
    newexpression.push(nstack.shift());
  }
  return newexpression;
}


// import { Instruction, IOP1, IOP2, IOP3, IVAR, IEXPR, ternaryInstruction, binaryInstruction, unaryInstruction } from './instruction';

/*export default*/ function substitute(tokens, variable, expr) {
  var newexpression = [];
  for (var i = 0; i < tokens.length; i++) {
    var item = tokens[i];
    var type = item.type;
    if (type === IVAR && item.value === variable) {
      for (var j = 0; j < expr.tokens.length; j++) {
        var expritem = expr.tokens[j];
        var replitem;
        if (expritem.type === IOP1) {
          replitem = unaryInstruction(expritem.value);
        } else if (expritem.type === IOP2) {
          replitem = binaryInstruction(expritem.value);
        } else if (expritem.type === IOP3) {
          replitem = ternaryInstruction(expritem.value);
        } else {
          replitem = new Instruction(expritem.type, expritem.value);
        }
        newexpression.push(replitem);
      }
    } else if (type === IEXPR) {
      newexpression.push(new Instruction(IEXPR, substitute(item.value, variable, expr)));
    } else {
      newexpression.push(item);
    }
  }
  return newexpression;
}



// import { INUMBER, IOP1, IOP2, IOP3, IVAR, IFUNCALL, IEXPR, IMEMBER } from './instruction';

/*export default*/ function evaluate(tokens, expr, values) {
  var nstack = [];
  var n1, n2, n3;
  var f;
  for (var i = 0; i < tokens.length; i++) {
    var item = tokens[i];
    var type = item.type;
    if (type === INUMBER) {
      nstack.push(item.value);
    } else if (type === IOP2) {
      n2 = nstack.pop();
      n1 = nstack.pop();
      f = expr.binaryOps[item.value];
      nstack.push(f(n1, n2));
    } else if (type === IOP3) {
      n3 = nstack.pop();
      n2 = nstack.pop();
      n1 = nstack.pop();
      if (item.value === '?') {
        nstack.push(evaluate(n1 ? n2 : n3, expr, values));
      } else {
        f = expr.ternaryOps[item.value];
        nstack.push(f(n1, n2, n3));
      }
    } else if (type === IVAR) {
      if (item.value in expr.functions) {
        nstack.push(expr.functions[item.value]);
      } else {
        var v = values[item.value];
        if (v !== undefined) {
          nstack.push(v);
        } else {
          throw new Error('undefined variable: ' + item.value);
        }
      }
    } else if (type === IOP1) {
      n1 = nstack.pop();
      f = expr.unaryOps[item.value];
      nstack.push(f(n1));
    } else if (type === IFUNCALL) {
      var argCount = item.value;
      var args = [];
      while (argCount-- > 0) {
        args.unshift(nstack.pop());
      }
      f = nstack.pop();
      if (f.apply && f.call) {
        nstack.push(f.apply(undefined, args));
      } else {
        throw new Error(f + ' is not a function');
      }
    } else if (type === IEXPR) {
      nstack.push(item.value);
    } else if (type === IMEMBER) {
      n1 = nstack.pop();
      nstack.push(n1[item.value]);
    } else {
      throw new Error('invalid Expression');
    }
  }
  if (nstack.length > 1) {
    throw new Error('invalid Expression (parity)');
  }
  return nstack[0];
}



// import { IVAR, IEXPR } from './instruction';
// import contains from './contains';

/*export default*/ function getSymbols(tokens, symbols) {
  for (var i = 0; i < tokens.length; i++) {
    var item = tokens[i];
    if (item.type === IVAR && !contains(symbols, item.value)) {
      symbols.push(item.value);
    } else if (item.type === IEXPR) {
      getSymbols(item.value, symbols);
    }
  }
}



// import { INUMBER, IOP1, IOP2, IOP3, IVAR, IFUNCALL, IEXPR, IMEMBER } from './instruction';

/*export default*/ function expressionToString(tokens, toJS) {
  var nstack = [];
  var n1, n2, n3;
  var f;
  for (var i = 0; i < tokens.length; i++) {
    var item = tokens[i];
    var type = item.type;
    if (type === INUMBER) {
      if (typeof item.value === 'number' && item.value < 0) {
        nstack.push('(' + item.value + ')');
      } else {
        nstack.push(escapeValue(item.value));
      }
    } else if (type === IOP2) {
      n2 = nstack.pop();
      n1 = nstack.pop();
      f = item.value;
      if (toJS) {
        if (f === '^') {
          nstack.push('Math.pow(' + n1 + ', ' + n2 + ')');
        } else if (f === 'and') {
          nstack.push('(!!' + n1 + ' && !!' + n2 + ')');
        } else if (f === 'or') {
          nstack.push('(!!' + n1 + ' || !!' + n2 + ')');
        } else if (f === '||') {
          nstack.push('(String(' + n1 + ') + String(' + n2 + '))');
        } else if (f === '==') {
          nstack.push('(' + n1 + ' === ' + n2 + ')');
        } else if (f === '!=') {
          nstack.push('(' + n1 + ' !== ' + n2 + ')');
        } else {
          nstack.push('(' + n1 + ' ' + f + ' ' + n2 + ')');
        }
      } else {
        nstack.push('(' + n1 + ' ' + f + ' ' + n2 + ')');
      }
    } else if (type === IOP3) {
      n3 = nstack.pop();
      n2 = nstack.pop();
      n1 = nstack.pop();
      f = item.value;
      if (f === '?') {
        nstack.push('(' + n1 + ' ? ' + n2 + ' : ' + n3 + ')');
      } else {
        throw new Error('invalid Expression');
      }
    } else if (type === IVAR) {
      nstack.push(item.value);
    } else if (type === IOP1) {
      n1 = nstack.pop();
      f = item.value;
      if (f === '-' || f === '+') {
        nstack.push('(' + f + n1 + ')');
      } else if (toJS) {
        if (f === 'not') {
          nstack.push('(' + '!' + n1 + ')');
        } else if (f === '!') {
          nstack.push('fac(' + n1 + ')');
        } else {
          nstack.push(f + '(' + n1 + ')');
        }
      } else if (f === '!') {
        nstack.push('(' + n1 + '!)');
      } else {
        nstack.push('(' + f + ' ' + n1 + ')');
      }
    } else if (type === IFUNCALL) {
      var argCount = item.value;
      var args = [];
      while (argCount-- > 0) {
        args.unshift(nstack.pop());
      }
      f = nstack.pop();
      nstack.push(f + '(' + args.join(', ') + ')');
    } else if (type === IMEMBER) {
      n1 = nstack.pop();
      nstack.push(n1 + '.' + item.value);
    } else if (type === IEXPR) {
      nstack.push('(' + expressionToString(item.value, toJS) + ')');
    } else {
      throw new Error('invalid Expression');
    }
  }
  if (nstack.length > 1) {
    throw new Error('invalid Expression (parity)');
  }
  return nstack[0];
}

function escapeValue(v) {
  if (typeof v === 'string') {
    return JSON.stringify(v).replace(/\u2028/g, '\\u2028').replace(/\u2029/g, '\\u2029');
  }
  return v;
}



// import { Token, TEOF, TOP, TNUMBER, TSTRING, TPAREN, TCOMMA, TNAME } from './token';

/*export*/ function TokenStream(parser, expression) {
  this.pos = 0;
  this.current = null;
  this.unaryOps = parser.unaryOps;
  this.binaryOps = parser.binaryOps;
  this.ternaryOps = parser.ternaryOps;
  this.consts = parser.consts;
  this.expression = expression;
  this.savedPosition = 0;
  this.savedCurrent = null;
}

TokenStream.prototype.newToken = function (type, value, pos) {
  return new Token(type, value, pos != null ? pos : this.pos);
};

TokenStream.prototype.save = function () {
  this.savedPosition = this.pos;
  this.savedCurrent = this.current;
};

TokenStream.prototype.restore = function () {
  this.pos = this.savedPosition;
  this.current = this.savedCurrent;
};

TokenStream.prototype.next = function () {
  if (this.pos >= this.expression.length) {
    return this.newToken(TEOF, 'EOF');
  }

  if (this.isWhitespace() || this.isComment()) {
    return this.next();
  } else if (this.isNumber() ||
      this.isOperator() ||
      this.isString() ||
      this.isParen() ||
      this.isComma() ||
      this.isNamedOp() ||
      this.isConst() ||
      this.isName()) {
    return this.current;
  } else {
    this.parseError('Unknown character "' + this.expression.charAt(this.pos) + '"');
  }
};

TokenStream.prototype.isString = function () {
  var r = false;
  var startPos = this.pos;
  var quote = this.expression.charAt(startPos);

  if (quote === '\'' || quote === '"') {
    var index = this.expression.indexOf(quote, startPos + 1);
    while (index >= 0 && this.pos < this.expression.length) {
      this.pos = index + 1;
      if (this.expression.charAt(index - 1) !== '\\') {
        var rawString = this.expression.substring(startPos + 1, index);
        this.current = this.newToken(TSTRING, this.unescape(rawString), startPos);
        r = true;
        break;
      }
      index = this.expression.indexOf(quote, index + 1);
    }
  }
  return r;
};

TokenStream.prototype.isParen = function () {
  var c = this.expression.charAt(this.pos);
  if (c === '(' || c === ')') {
    this.current = this.newToken(TPAREN, c);
    this.pos++;
    return true;
  }
  return false;
};

TokenStream.prototype.isComma = function () {
  var c = this.expression.charAt(this.pos);
  if (c === ',') {
    this.current = this.newToken(TCOMMA, ',');
    this.pos++;
    return true;
  }
  return false;
};

TokenStream.prototype.isConst = function () {
  var startPos = this.pos;
  var i = startPos;
  for (; i < this.expression.length; i++) {
    var c = this.expression.charAt(i);
    if (c.toUpperCase() === c.toLowerCase()) {
      if (i === this.pos || (c !== '_' && c !== '.' && (c < '0' || c > '9'))) {
        break;
      }
    }
  }
  if (i > startPos) {
    var str = this.expression.substring(startPos, i);
    if (str in this.consts) {
      this.current = this.newToken(TNUMBER, this.consts[str]);
      this.pos += str.length;
      return true;
    }
  }
  return false;
};

TokenStream.prototype.isNamedOp = function () {
  var startPos = this.pos;
  var i = startPos;
  for (; i < this.expression.length; i++) {
    var c = this.expression.charAt(i);
    if (c.toUpperCase() === c.toLowerCase()) {
      if (i === this.pos || (c !== '_' && (c < '0' || c > '9'))) {
        break;
      }
    }
  }
  if (i > startPos) {
    var str = this.expression.substring(startPos, i);
    if (str in this.binaryOps || str in this.unaryOps || str in this.ternaryOps) {
      this.current = this.newToken(TOP, str);
      this.pos += str.length;
      return true;
    }
  }
  return false;
};

TokenStream.prototype.isName = function () {
  var startPos = this.pos;
  var i = startPos;
  for (; i < this.expression.length; i++) {
    var c = this.expression.charAt(i);
    if (c.toUpperCase() === c.toLowerCase()) {
      if (i === this.pos || (c !== '_' && (c < '0' || c > '9'))) {
        break;
      }
    }
  }
  if (i > startPos) {
    var str = this.expression.substring(startPos, i);
    this.current = this.newToken(TNAME, str);
    this.pos += str.length;
    return true;
  }
  return false;
};

TokenStream.prototype.isWhitespace = function () {
  var r = false;
  var c = this.expression.charAt(this.pos);
  while (c === ' ' || c === '\t' || c === '\n' || c === '\r') {
    r = true;
    this.pos++;
    if (this.pos >= this.expression.length) {
      break;
    }
    c = this.expression.charAt(this.pos);
  }
  return r;
};

var codePointPattern = /^[0-9a-f]{4}$/i;

TokenStream.prototype.unescape = function (v) {
  var index = v.indexOf('\\');
  if (index < 0) {
    return v;
  }

  var buffer = v.substring(0, index);
  while (index >= 0) {
    var c = v.charAt(++index);
    switch (c) {
      case '\'':
        buffer += '\'';
        break;
      case '"':
        buffer += '"';
        break;
      case '\\':
        buffer += '\\';
        break;
      case '/':
        buffer += '/';
        break;
      case 'b':
        buffer += '\b';
        break;
      case 'f':
        buffer += '\f';
        break;
      case 'n':
        buffer += '\n';
        break;
      case 'r':
        buffer += '\r';
        break;
      case 't':
        buffer += '\t';
        break;
      case 'u':
        // interpret the following 4 characters as the hex of the unicode code point
        var codePoint = v.substring(index + 1, index + 5);
        if (!codePointPattern.test(codePoint)) {
          this.parseError('Illegal escape sequence: \\u' + codePoint);
        }
        buffer += String.fromCharCode(parseInt(codePoint, 16));
        index += 4;
        break;
      default:
        throw this.parseError('Illegal escape sequence: "\\' + c + '"');
    }
    ++index;
    var backslash = v.indexOf('\\', index);
    buffer += v.substring(index, backslash < 0 ? v.length : backslash);
    index = backslash;
  }

  return buffer;
};

TokenStream.prototype.isComment = function () {
  var c = this.expression.charAt(this.pos);
  if (c === '/' && this.expression.charAt(this.pos + 1) === '*') {
    this.pos = this.expression.indexOf('*/', this.pos) + 2;
    if (this.pos === 1) {
      this.pos = this.expression.length;
    }
    return true;
  }
  return false;
};

TokenStream.prototype.isNumber = function () {
  var valid = false;
  var pos = this.pos;
  var startPos = pos;
  var resetPos = pos;
  var foundDot = false;
  var foundDigits = false;
  var c;

  while (pos < this.expression.length) {
    c = this.expression.charAt(pos);
    if ((c >= '0' && c <= '9') || (!foundDot && c === '.')) {
      if (c === '.') {
        foundDot = true;
      } else {
        foundDigits = true;
      }
      pos++;
      valid = foundDigits;
    } else {
      break;
    }
  }

  if (valid) {
    resetPos = pos;
  }

  if (c === 'e' || c === 'E') {
    pos++;
    var acceptSign = true;
    var validExponent = false;
    while (pos < this.expression.length) {
      c = this.expression.charAt(pos);
      if (acceptSign && (c === '+' || c === '-')) {
        acceptSign = false;
      } else if (c >= '0' && c <= '9') {
        validExponent = true;
        acceptSign = false;
      } else {
        break;
      }
      pos++;
    }

    if (!validExponent) {
      pos = resetPos;
    }
  }

  if (valid) {
    this.current = this.newToken(TNUMBER, parseFloat(this.expression.substring(startPos, pos)));
    this.pos = pos;
  } else {
    this.pos = resetPos;
  }
  return valid;
};

TokenStream.prototype.isOperator = function () {
  var c = this.expression.charAt(this.pos);

  if (c === '+' || c === '-' || c === '*' || c === '/' || c === '%' || c === '^' || c === '?' || c === ':' || c === '.') {
    this.current = this.newToken(TOP, c);
  } else if (c === '∙' || c === '•') {
    this.current = this.newToken(TOP, '*');
  } else if (c === '>') {
    if (this.expression.charAt(this.pos + 1) === '=') {
      this.current = this.newToken(TOP, '>=');
      this.pos++;
    } else {
      this.current = this.newToken(TOP, '>');
    }
  } else if (c === '<') {
    if (this.expression.charAt(this.pos + 1) === '=') {
      this.current = this.newToken(TOP, '<=');
      this.pos++;
    } else {
      this.current = this.newToken(TOP, '<');
    }
  } else if (c === '|') {
    if (this.expression.charAt(this.pos + 1) === '|') {
      this.current = this.newToken(TOP, '||');
      this.pos++;
    } else {
      return false;
    }
  } else if (c === '=') {
    if (this.expression.charAt(this.pos + 1) === '=') {
      this.current = this.newToken(TOP, '==');
      this.pos++;
    } else {
      return false;
    }
  } else if (c === '!') {
    if (this.expression.charAt(this.pos + 1) === '=') {
      this.current = this.newToken(TOP, '!=');
      this.pos++;
    } else {
      this.current = this.newToken(TOP, c);
    }
  } else {
    return false;
  }
  this.pos++;
  return true;
};

TokenStream.prototype.getCoordinates = function () {
  var line = 0;
  var column;
  var newline = -1;
  do {
    line++;
    column = this.pos - newline;
    newline = this.expression.indexOf('\n', newline + 1);
  } while (newline >= 0 && newline < this.pos);

  return {
    line: line,
    column: column
  };
};

TokenStream.prototype.parseError = function (msg) {
  var coords = this.getCoordinates();
  throw new Error('parse error [' + coords.line + ':' + coords.column + ']: ' + msg);
};



// import { TOP, TNUMBER, TSTRING, TPAREN, TCOMMA, TNAME } from './token';
// import { Instruction, INUMBER, IVAR, IFUNCALL, IEXPR, IMEMBER, ternaryInstruction, binaryInstruction, unaryInstruction } from './instruction';
// import contains from './contains';

/*export*/ function ParserState(parser, tokenStream, options) {
  this.parser = parser;
  this.tokens = tokenStream;
  this.current = null;
  this.nextToken = null;
  this.next();
  this.savedCurrent = null;
  this.savedNextToken = null;
  this.allowMemberAccess = options.allowMemberAccess !== false;
}

ParserState.prototype.next = function () {
  this.current = this.nextToken;
  return (this.nextToken = this.tokens.next());
};

ParserState.prototype.tokenMatches = function (token, value) {
  if (typeof value === 'undefined') {
    return true;
  } else if (Array.isArray(value)) {
    return contains(value, token.value);
  } else if (typeof value === 'function') {
    return value(token);
  } else {
    return token.value === value;
  }
};

ParserState.prototype.save = function () {
  this.savedCurrent = this.current;
  this.savedNextToken = this.nextToken;
  this.tokens.save();
};

ParserState.prototype.restore = function () {
  this.tokens.restore();
  this.current = this.savedCurrent;
  this.nextToken = this.savedNextToken;
};

ParserState.prototype.accept = function (type, value) {
  if (this.nextToken.type === type && this.tokenMatches(this.nextToken, value)) {
    this.next();
    return true;
  }
  return false;
};

ParserState.prototype.expect = function (type, value) {
  if (!this.accept(type, value)) {
    var coords = this.tokens.getCoordinates();
    throw new Error('parse error [' + coords.line + ':' + coords.column + ']: Expected ' + (value || type));
  }
};

ParserState.prototype.parseAtom = function (instr) {
  if (this.accept(TNAME)) {
    instr.push(new Instruction(IVAR, this.current.value));
  } else if (this.accept(TNUMBER)) {
    instr.push(new Instruction(INUMBER, this.current.value));
  } else if (this.accept(TSTRING)) {
    instr.push(new Instruction(INUMBER, this.current.value));
  } else if (this.accept(TPAREN, '(')) {
    this.parseExpression(instr);
    this.expect(TPAREN, ')');
  } else {
    throw new Error('unexpected ' + this.nextToken);
  }
};

ParserState.prototype.parseExpression = function (instr) {
  this.parseConditionalExpression(instr);
};

ParserState.prototype.parseConditionalExpression = function (instr) {
  this.parseOrExpression(instr);
  while (this.accept(TOP, '?')) {
    var trueBranch = [];
    var falseBranch = [];
    this.parseConditionalExpression(trueBranch);
    this.expect(TOP, ':');
    this.parseConditionalExpression(falseBranch);
    instr.push(new Instruction(IEXPR, trueBranch));
    instr.push(new Instruction(IEXPR, falseBranch));
    instr.push(ternaryInstruction('?'));
  }
};

ParserState.prototype.parseOrExpression = function (instr) {
  this.parseAndExpression(instr);
  while (this.accept(TOP, 'or')) {
    this.parseAndExpression(instr);
    instr.push(binaryInstruction('or'));
  }
};

ParserState.prototype.parseAndExpression = function (instr) {
  this.parseComparison(instr);
  while (this.accept(TOP, 'and')) {
    this.parseComparison(instr);
    instr.push(binaryInstruction('and'));
  }
};

var COMPARISON_OPERATORS = ['==', '!=', '<', '<=', '>=', '>'];

ParserState.prototype.parseComparison = function (instr) {
  this.parseAddSub(instr);
  while (this.accept(TOP, COMPARISON_OPERATORS)) {
    var op = this.current;
    this.parseAddSub(instr);
    instr.push(binaryInstruction(op.value));
  }
};

var ADD_SUB_OPERATORS = ['+', '-', '||'];

ParserState.prototype.parseAddSub = function (instr) {
  this.parseTerm(instr);
  while (this.accept(TOP, ADD_SUB_OPERATORS)) {
    var op = this.current;
    this.parseTerm(instr);
    instr.push(binaryInstruction(op.value));
  }
};

var TERM_OPERATORS = ['*', '/', '%'];

ParserState.prototype.parseTerm = function (instr) {
  this.parseFactor(instr);
  while (this.accept(TOP, TERM_OPERATORS)) {
    var op = this.current;
    this.parseFactor(instr);
    instr.push(binaryInstruction(op.value));
  }
};

ParserState.prototype.parseFactor = function (instr) {
  var unaryOps = this.tokens.unaryOps;
  function isPrefixOperator(token) {
    return token.value in unaryOps;
  }

  this.save();
  if (this.accept(TOP, isPrefixOperator)) {
    if ((this.current.value !== '-' && this.current.value !== '+' && this.nextToken.type === TPAREN && this.nextToken.value === '(')) {
      this.restore();
      this.parseExponential(instr);
    } else {
      var op = this.current;
      this.parseFactor(instr);
      instr.push(unaryInstruction(op.value));
    }
  } else {
    this.parseExponential(instr);
  }
};

ParserState.prototype.parseExponential = function (instr) {
  this.parsePostfixExpression(instr);
  while (this.accept(TOP, '^')) {
    this.parseFactor(instr);
    instr.push(binaryInstruction('^'));
  }
};

ParserState.prototype.parsePostfixExpression = function (instr) {
  this.parseFunctionCall(instr);
  while (this.accept(TOP, '!')) {
    instr.push(unaryInstruction('!'));
  }
};

ParserState.prototype.parseFunctionCall = function (instr) {
  var unaryOps = this.tokens.unaryOps;
  function isPrefixOperator(token) {
    return token.value in unaryOps;
  }

  if (this.accept(TOP, isPrefixOperator)) {
    var op = this.current;
    this.parseAtom(instr);
    instr.push(unaryInstruction(op.value));
  } else {
    this.parseMemberExpression(instr);
    while (this.accept(TPAREN, '(')) {
      if (this.accept(TPAREN, ')')) {
        instr.push(new Instruction(IFUNCALL, 0));
      } else {
        var argCount = this.parseArgumentList(instr);
        instr.push(new Instruction(IFUNCALL, argCount));
      }
    }
  }
};

ParserState.prototype.parseArgumentList = function (instr) {
  var argCount = 0;

  while (!this.accept(TPAREN, ')')) {
    this.parseExpression(instr);
    ++argCount;
    while (this.accept(TCOMMA)) {
      this.parseExpression(instr);
      ++argCount;
    }
  }

  return argCount;
};

ParserState.prototype.parseMemberExpression = function (instr) {
  this.parseAtom(instr);
  while (this.accept(TOP, '.')) {
    if (!this.allowMemberAccess) {
      throw new Error('unexpected ".", member access is not permitted');
    }

    this.expect(TNAME);
    instr.push(new Instruction(IMEMBER, this.current.value));
  }
};



// import simplify from './simplify';
// import substitute from './substitute';
// import evaluate from './evaluate';
// import expressionToString from './expression-to-string';
// import getSymbols from './get-symbols';

/*export*/ function Expression(tokens, parser) {
  this.tokens = tokens;
  this.parser = parser;
  this.unaryOps = parser.unaryOps;
  this.binaryOps = parser.binaryOps;
  this.ternaryOps = parser.ternaryOps;
  this.functions = parser.functions;
}

Expression.prototype.simplify = function (values) {
  values = values || {};
  return new Expression(simplify(this.tokens, this.unaryOps, this.binaryOps, this.ternaryOps, values), this.parser);
};

Expression.prototype.substitute = function (variable, expr) {
  if (!(expr instanceof Expression)) {
    expr = this.parser.parse(String(expr));
  }

  return new Expression(substitute(this.tokens, variable, expr), this.parser);
};

Expression.prototype.evaluate = function (values) {
  values = values || {};
  return evaluate(this.tokens, this, values);
};

Expression.prototype.toString = function () {
  return expressionToString(this.tokens, false);
};

Expression.prototype.symbols = function () {
  var vars = [];
  getSymbols(this.tokens, vars);
  return vars;
};

Expression.prototype.variables = function () {
  var vars = [];
  getSymbols(this.tokens, vars);
  var functions = this.functions;
  return vars.filter(function (name) {
    return !(name in functions);
  });
};

Expression.prototype.toJSFunction = function (param, variables) {
  var expr = this;
  var f = new Function(param, 'with(this.functions) with (this.ternaryOps) with (this.binaryOps) with (this.unaryOps) { return ' + expressionToString(this.simplify(variables).tokens, true) + '; }'); // eslint-disable-line no-new-func
  return function () {
    return f.apply(expr, arguments);
  };
};



/*export*/ function add(a, b) {
  return Number(a) + Number(b);
}

/*export*/ function sub(a, b) {
  return a - b;
}

/*export*/ function mul(a, b) {
  return a * b;
}

/*export*/ function div(a, b) {
  return a / b;
}

/*export*/ function mod(a, b) {
  return a % b;
}

/*export*/ function concat(a, b) {
  return '' + a + b;
}

/*export*/ function equal(a, b) {
  return a === b;
}

/*export*/ function notEqual(a, b) {
  return a !== b;
}

/*export*/ function greaterThan(a, b) {
  return a > b;
}

/*export*/ function lessThan(a, b) {
  return a < b;
}

/*export*/ function greaterThanEqual(a, b) {
  return a >= b;
}

/*export*/ function lessThanEqual(a, b) {
  return a <= b;
}

/*export*/ function andOperator(a, b) {
  return Boolean(a && b);
}

/*export*/ function orOperator(a, b) {
  return Boolean(a || b);
}

/*export*/ function sinh(a) {
  return ((Math.exp(a) - Math.exp(-a)) / 2);
}

/*export*/ function cosh(a) {
  return ((Math.exp(a) + Math.exp(-a)) / 2);
}

/*export*/ function tanh(a) {
  if (a === Infinity) return 1;
  if (a === -Infinity) return -1;
  return (Math.exp(a) - Math.exp(-a)) / (Math.exp(a) + Math.exp(-a));
}

/*export*/ function asinh(a) {
  if (a === -Infinity) return a;
  return Math.log(a + Math.sqrt((a * a) + 1));
}

/*export*/ function acosh(a) {
  return Math.log(a + Math.sqrt((a * a) - 1));
}

/*export*/ function atanh(a) {
  return (Math.log((1 + a) / (1 - a)) / 2);
}

/*export*/ function log10(a) {
  return Math.log(a) * Math.LOG10E;
}

/*export*/ function neg(a) {
  return -a;
}

/*export*/ function not(a) {
  return !a;
}

/*export*/ function trunc(a) {
  return a < 0 ? Math.ceil(a) : Math.floor(a);
}

/*export*/ function random(a) {
  return Math.random() * (a || 1);
}

/*export*/ function factorial(a) { // a!
  return gamma(a + 1);
}

function isInteger(value) {
  return isFinite(value) && (value === Math.round(value));
}

var GAMMA_G = 4.7421875;
var GAMMA_P = [
  0.99999999999999709182,
  57.156235665862923517, -59.597960355475491248,
  14.136097974741747174, -0.49191381609762019978,
  0.33994649984811888699e-4,
  0.46523628927048575665e-4, -0.98374475304879564677e-4,
  0.15808870322491248884e-3, -0.21026444172410488319e-3,
  0.21743961811521264320e-3, -0.16431810653676389022e-3,
  0.84418223983852743293e-4, -0.26190838401581408670e-4,
  0.36899182659531622704e-5
];

// Gamma function from math.js
/*export*/ function gamma(n) {
  var t, x;

  if (isInteger(n)) {
    if (n <= 0) {
      return isFinite(n) ? Infinity : NaN;
    }

    if (n > 171) {
      return Infinity; // Will overflow
    }

    var value = n - 2;
    var res = n - 1;
    while (value > 1) {
      res *= value;
      value--;
    }

    if (res === 0) {
      res = 1; // 0! is per definition 1
    }

    return res;
  }

  if (n < 0.5) {
    return Math.PI / (Math.sin(Math.PI * n) * gamma(1 - n));
  }

  if (n >= 171.35) {
    return Infinity; // will overflow
  }

  if (n > 85.0) { // Extended Stirling Approx
    var twoN = n * n;
    var threeN = twoN * n;
    var fourN = threeN * n;
    var fiveN = fourN * n;
    return Math.sqrt(2 * Math.PI / n) * Math.pow((n / Math.E), n) *
      (1 + (1 / (12 * n)) + (1 / (288 * twoN)) - (139 / (51840 * threeN)) -
      (571 / (2488320 * fourN)) + (163879 / (209018880 * fiveN)) +
      (5246819 / (75246796800 * fiveN * n)));
  }

  --n;
  x = GAMMA_P[0];
  for (var i = 1; i < GAMMA_P.length; ++i) {
    x += GAMMA_P[i] / (n + i);
  }

  t = n + GAMMA_G + 0.5;
  return Math.sqrt(2 * Math.PI) * Math.pow(t, n + 0.5) * Math.exp(-t) * x;
}

/*export*/ function stringLength(s) {
  return String(s).length;
}

/*export*/ function hypot() {
  var sum = 0;
  var larg = 0;
  for (var i = 0; i < arguments.length; i++) {
    var arg = Math.abs(arguments[i]);
    var div;
    if (larg < arg) {
      div = larg / arg;
      sum = (sum * div * div) + 1;
      larg = arg;
    } else if (arg > 0) {
      div = arg / larg;
      sum += div * div;
    } else {
      sum += arg;
    }
  }
  return larg === Infinity ? Infinity : larg * Math.sqrt(sum);
}

/*export*/ function condition(cond, yep, nope) {
  return cond ? yep : nope;
}



// import { TEOF } from './token';
// import { TokenStream } from './token-stream';
// import { ParserState } from './parser-state';
// import { Expression } from './expression';
// import {
//   add,
//   sub,
//   mul,
//   div,
//   mod,
//   concat,
//   equal,
//   notEqual,
//   greaterThan,
//   lessThan,
//   greaterThanEqual,
//   lessThanEqual,
//   andOperator,
//   orOperator,
//   sinh,
//   cosh,
//   tanh,
//   asinh,
//   acosh,
//   atanh,
//   log10,
//   neg,
//   not,
//   trunc,
//   random,
//   factorial,
//   gamma,
//   stringLength,
//   hypot,
//   condition
// } from './functions';

export function Parser(options) {
  this.options = options || {};
  this.unaryOps = {
    sin: Math.sin,
    cos: Math.cos,
    tan: Math.tan,
    asin: Math.asin,
    acos: Math.acos,
    atan: Math.atan,
    sinh: Math.sinh || sinh,
    cosh: Math.cosh || cosh,
    tanh: Math.tanh || tanh,
    asinh: Math.asinh || asinh,
    acosh: Math.acosh || acosh,
    atanh: Math.atanh || atanh,
    sqrt: Math.sqrt,
    log: Math.log,
    ln: Math.log,
    lg: Math.log10 || log10,
    log10: Math.log10 || log10,
    abs: Math.abs,
    ceil: Math.ceil,
    floor: Math.floor,
    round: Math.round,
    trunc: Math.trunc || trunc,
    '-': neg,
    '+': Number,
    exp: Math.exp,
    not: not,
    length: stringLength,
    '!': factorial
  };

  this.binaryOps = {
    '+': add,
    '-': sub,
    '*': mul,
    '/': div,
    '%': mod,
    '^': Math.pow,
    '||': concat,
    '==': equal,
    '!=': notEqual,
    '>': greaterThan,
    '<': lessThan,
    '>=': greaterThanEqual,
    '<=': lessThanEqual,
    and: andOperator,
    or: orOperator
  };

  this.ternaryOps = {
    '?': condition
  };

  this.functions = {
    random: random,
    fac: factorial,
    min: Math.min,
    max: Math.max,
    hypot: Math.hypot || hypot,
    pyt: Math.hypot || hypot, // backward compat
    pow: Math.pow,
    atan2: Math.atan2,
    'if': condition,
    gamma: gamma
  };

  this.consts = {
    E: Math.E,
    PI: Math.PI,
    'true': true,
    'false': false
  };
}

Parser.prototype.parse = function (expr) {
  var instr = [];
  var parserState = new ParserState(
    this,
    new TokenStream(this, expr),
    { allowMemberAccess: this.options.allowMemberAccess }
  );

  parserState.parseExpression(instr);
  parserState.expect(TEOF, 'EOF');

  return new Expression(instr, this);
};

Parser.prototype.evaluate = function (expr, variables) {
  return this.parse(expr).evaluate(variables);
};

var sharedParser = new Parser();

Parser.parse = function (expr) {
  return sharedParser.parse(expr);
};

Parser.evaluate = function (expr, variables) {
  return sharedParser.parse(expr).evaluate(variables);
};

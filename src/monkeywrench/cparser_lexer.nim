# Lightweight tokenizer for a bindings-oriented C parser.
#
# The parser is intended to run on preprocessed C, but the lexer still ignores
# line directives and basic comments so it can be used directly in tests.

import cparser_ast

const
  CPunctuators = [
    ">>=", "<<=", "...", "->", "++", "--", "<=", ">=", "==", "!=",
    "&&", "||", "<<", ">>", "+=", "-=", "*=", "/=", "%=", "&=", "^=",
    "|=", "##", "::",
    "{", "}", "(", ")", "[", "]", ";", ",", ".", "&", "*", "+", "-",
    "~", "!", "/", "%", "<", ">", "^", "|", "?", ":", "=", "#"
  ]

proc isIdentStart(c: char): bool {.inline.} =
  c == '_' or c in {'a'..'z'} or c in {'A'..'Z'}

proc isIdentContinue(c: char): bool {.inline.} =
  isIdentStart(c) or c in {'0'..'9'}

proc isKeyword(s: string): bool =
  s in [
    "void", "_Bool", "char", "short", "int", "long", "float", "double",
    "signed", "unsigned", "struct", "union", "enum", "typedef", "extern",
    "static", "inline", "const", "volatile", "restrict", "__restrict",
    "__restrict__", "_Noreturn", "_Thread_local", "__thread", "_Atomic",
    "_Alignas", "typeof", "__typeof__", "__attribute__", "__declspec",
    "__cdecl", "__stdcall", "__fastcall", "__vectorcall", "__inline__",
    "__const__", "__volatile__", "__extension__", "asm", "__asm__"
  ]

proc addTok(tokens: var seq[CToken]; kind: CTokenKind; lexeme: string; line, col: int) =
  tokens.add CToken(kind: kind, lexeme: lexeme, line: line, col: col)

proc tokenizeC*(source: string): seq[CToken] =
  result = @[]
  var i = 0
  var line = 1
  var col = 1
  var lineStart = true

  template advanceChar() =
    if source[i] == '\n':
      inc line
      col = 1
      lineStart = true
    else:
      inc col
      if source[i] notin {' ', '\t', '\r'}:
        lineStart = false
    inc i

  proc skipLineDirective() =
    while i < source.len and source[i] != '\n':
      advanceChar()

  while i < source.len:
    let c = source[i]

    if c in {' ', '\t', '\r', '\n'}:
      advanceChar()
      continue

    if lineStart and c == '#':
      skipLineDirective()
      continue

    if c == '/' and i + 1 < source.len:
      if source[i + 1] == '/':
        advanceChar()
        advanceChar()
        while i < source.len and source[i] != '\n':
          advanceChar()
        continue
      if source[i + 1] == '*':
        advanceChar()
        advanceChar()
        while i + 1 < source.len and not (source[i] == '*' and source[i + 1] == '/'):
          advanceChar()
        if i + 1 >= source.len:
          raise newException(ValueError, "unterminated block comment")
        advanceChar()
        advanceChar()
        continue

    if isIdentStart(c):
      let start = i
      let startLine = line
      let startCol = col
      advanceChar()
      while i < source.len and isIdentContinue(source[i]):
        advanceChar()
      let lexeme = source[start..<i]
      addTok result, (if isKeyword(lexeme): tkKeyword else: tkIdent), lexeme, startLine, startCol
      continue

    if c in {'0'..'9'}:
      let start = i
      let startLine = line
      let startCol = col
      advanceChar()
      while i < source.len and source[i] notin {' ', '\t', '\r', '\n'}:
        let d = source[i]
        if d in {';', ',', ')', ']', '}', ':'}:
          break
        if d == '/' and i + 1 < source.len and source[i + 1] in {'/', '*'}:
          break
        if d in {'+', '-'} and source[i - 1] notin {'e', 'E', 'p', 'P'}:
          break
        if d in {'(', '[', '{'}:
          break
        advanceChar()
      addTok result, tkNumber, source[start..<i], startLine, startCol
      continue

    if c == '"' or c == '\'':
      let quote = c
      let start = i
      let startLine = line
      let startCol = col
      var closed = false
      advanceChar()
      while i < source.len:
        if source[i] == '\\':
          advanceChar()
          if i < source.len:
            advanceChar()
          continue
        if source[i] == quote:
          advanceChar()
          closed = true
          break
        advanceChar()
      if not closed:
        let kindName = if quote == '"': "string" else: "character"
        raise newException(
          ValueError,
          "unterminated " & kindName & " literal at " & $startLine & ":" & $startCol
        )
      let kind = if quote == '"': tkString else: tkChar
      addTok result, kind, source[start..<i], startLine, startCol
      continue

    var matched = false
    for punct in CPunctuators:
      if i + punct.len <= source.len and source[i ..< i + punct.len] == punct:
        addTok result, tkPunct, punct, line, col
        for _ in 0..<punct.len:
          advanceChar()
        matched = true
        break
    if matched:
      continue

    raise newException(ValueError,
      "unexpected character '" & c & "' at " & $line & ":" & $col)

  addTok result, tkEof, "", line, col

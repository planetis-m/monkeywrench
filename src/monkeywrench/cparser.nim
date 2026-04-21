# Lightweight C declaration parser for bindings generation.
#
# Primary implementation reference: chibicc's declaration parser.
# Secondary oracle/reference: pycparser's typedef handling and fake-header
# strategy. This module intentionally targets preprocessed C and top-level
# declarations, not a complete C front-end.

import std/[sets, strutils, tables]
import cparser_ast, cparser_lexer

type
  CParseError* = object of ValueError

  CDeclSpec* = object
    storage: CStorageClasses
    callConv: CCallConv
    qualifiers: CTypeQuals
    baseType: CType

  Parser = object
    tokens: seq[CToken]
    pos: int
    typedefNames: HashSet[string]
    tagTypes: Table[string, CType]

proc parseTopLevelDecls*(source: string): seq[CDecl]

proc initParser(source: string): Parser =
  Parser(tokens: tokenizeC(source), typedefNames: initHashSet[string](),
         tagTypes: initTable[string, CType]())

proc cur(p: Parser): CToken {.inline.} = p.tokens[p.pos]
proc peek(p: Parser; offset = 1): CToken {.inline.} = p.tokens[p.pos + offset]

proc fail(p: Parser; msg: string): ref CParseError =
  let tok = p.cur
  newException(CParseError, msg & " at " & $tok.line & ":" & $tok.col &
    (if tok.lexeme.len == 0: "" else: " near `" & tok.lexeme & "`"))

proc at(p: Parser; lexeme: string): bool {.inline.} =
  p.cur.lexeme == lexeme

proc atKind(p: Parser; kind: CTokenKind): bool {.inline.} =
  p.cur.kind == kind

proc bump(p: var Parser) {.inline.} =
  if p.pos < p.tokens.len - 1:
    inc p.pos

proc consume(p: var Parser; lexeme: string): bool =
  result = false
  if p.at(lexeme):
    p.bump()
    result = true

proc expect(p: var Parser; lexeme: string) =
  if not p.consume(lexeme):
    raise p.fail("expected `" & lexeme & "`")

proc takeIdent(p: var Parser): string =
  if p.cur.kind notin {tkIdent, tkKeyword}:
    raise p.fail("expected identifier")
  result = p.cur.lexeme
  p.bump()

proc tagKey(kind: CTypeKind; tag: string): string =
  $ord(kind) & ":" & tag

proc callConvFromLexeme(lexeme: string): CCallConv =
  case lexeme
  of "__cdecl": ccCdecl
  of "__stdcall": ccStdcall
  of "__fastcall": ccFastcall
  of "__vectorcall": ccVectorcall
  else: ccNone

proc applyCallConv(typ: CType; cc: CCallConv): CType =
  if typ.isNil or cc == ccNone:
    return typ
  case typ.kind
  of ctFunction:
    typ.callConv = cc
  of ctPointer:
    discard applyCallConv(typ.base, cc)
  of ctArray:
    discard applyCallConv(typ.elem, cc)
  else:
    discard
  typ

proc skipBalanced(p: var Parser; openLex, closeLex: string) =
  p.expect(openLex)
  var depth = 1
  while depth > 0:
    if p.atKind(tkEof):
      raise p.fail("unterminated balanced token sequence")
    if p.at(openLex):
      inc depth
    elif p.at(closeLex):
      dec depth
    p.bump()

proc skipAttribute(p: var Parser): bool =
  result = false
  case p.cur.lexeme
  of "__attribute__":
    p.bump()
    p.skipBalanced("(", ")")
    result = true
  of "__declspec":
    p.bump()
    p.skipBalanced("(", ")")
    result = true
  of "__extension__", "__inline__", "__const__", "__volatile__", "asm", "__asm__":
    p.bump()
    if p.at("("):
      p.skipBalanced("(", ")")
    result = true
  else:
    discard

proc collectUntil(p: var Parser; stopLexemes: set[char]): string =
  var parts: seq[string] = @[]
  var parenDepth = 0
  var bracketDepth = 0
  var braceDepth = 0
  while not p.atKind(tkEof):
    if parenDepth == 0 and bracketDepth == 0 and braceDepth == 0 and
        p.cur.lexeme.len == 1 and p.cur.lexeme[0] in stopLexemes:
      break
    case p.cur.lexeme
    of "(":
      inc parenDepth
    of ")":
      dec parenDepth
    of "[":
      inc bracketDepth
    of "]":
      dec bracketDepth
    of "{":
      inc braceDepth
    of "}":
      dec braceDepth
    else:
      discard
    parts.add p.cur.lexeme
    p.bump()
  result = parts.join(" ")

proc collectUntilTopLevel(p: var Parser; delimiters: set[char]): string =
  result = collectUntil(p, delimiters)

proc parseTypeName(p: var Parser): CType
proc parseTypeofSpecifier(p: var Parser): CType
proc parseConstExpr(p: var Parser): CExpr
proc parseConditionalExpr(p: var Parser): CExpr
proc parseLogOrExpr(p: var Parser): CExpr
proc parseLogAndExpr(p: var Parser): CExpr
proc parseBitOrExpr(p: var Parser): CExpr
proc parseBitXorExpr(p: var Parser): CExpr
proc parseBitAndExpr(p: var Parser): CExpr
proc parseEqualityExpr(p: var Parser): CExpr
proc parseRelationalExpr(p: var Parser): CExpr
proc parseShiftExpr(p: var Parser): CExpr
proc parseAddExpr(p: var Parser): CExpr
proc parseMulExpr(p: var Parser): CExpr
proc parseCastExpr(p: var Parser): CExpr
proc parseUnaryExpr(p: var Parser): CExpr

func isTypeNameStart(p: Parser): bool =
  case p.cur.lexeme
  of "void", "_Bool", "char", "short", "int", "long", "float", "double",
     "signed", "unsigned", "const", "volatile", "__volatile__", "restrict",
     "__restrict", "__restrict__", "_Atomic", "struct", "union", "enum",
     "typedef", "extern", "static", "inline", "_Thread_local", "__thread",
     "__cdecl", "__stdcall", "__fastcall", "__vectorcall":
    true
  else:
    p.cur.kind == tkIdent and p.cur.lexeme in p.typedefNames

proc isTypeNameAhead(p: Parser): bool =
  if not p.at("("):
    return false
  var probe = p
  probe.bump()
  if not probe.isTypeNameStart():
    return false
  try:
    discard probe.parseTypeName()
    result = probe.at(")")
  except CParseError:
    result = false

proc parsePrimaryExpr(p: var Parser): CExpr =
  case p.cur.kind
  of tkNumber:
    result = numberExpr(p.cur.lexeme)
    p.bump()
  of tkChar:
    result = charExpr(p.cur.lexeme)
    p.bump()
  of tkIdent, tkKeyword:
    result = identExpr(p.cur.lexeme)
    p.bump()
  else:
    if p.consume("("):
      result = p.parseConstExpr()
      p.expect(")")
    else:
      raise p.fail("expected constant expression")

proc parseUnaryExpr(p: var Parser): CExpr =
  case p.cur.lexeme
  of "sizeof":
    p.bump()
    if p.isTypeNameAhead():
      p.expect("(")
      result = sizeofTypeExpr(p.parseTypeName())
      p.expect(")")
    else:
      result = sizeofExpr(p.parseUnaryExpr())
  of "_Alignof", "__alignof__", "__alignof":
    p.bump()
    p.expect("(")
    result = alignofTypeExpr(p.parseTypeName())
    p.expect(")")
  of "+", "-", "!", "~":
    let op = p.cur.lexeme
    p.bump()
    result = unaryExpr(op, p.parseUnaryExpr())
  else:
    result = p.parsePrimaryExpr()

proc parseCastExpr(p: var Parser): CExpr =
  if p.isTypeNameAhead():
    p.expect("(")
    let targetType = p.parseTypeName()
    p.expect(")")
    result = castExpr(targetType, p.parseCastExpr())
  else:
    result = p.parseUnaryExpr()

proc parseMulExpr(p: var Parser): CExpr =
  result = p.parseCastExpr()
  while p.cur.lexeme in ["*", "/", "%"]:
    let op = p.cur.lexeme
    p.bump()
    result = binaryExpr(op, result, p.parseCastExpr())

proc parseAddExpr(p: var Parser): CExpr =
  result = p.parseMulExpr()
  while p.cur.lexeme in ["+", "-"]:
    let op = p.cur.lexeme
    p.bump()
    result = binaryExpr(op, result, p.parseMulExpr())

proc parseShiftExpr(p: var Parser): CExpr =
  result = p.parseAddExpr()
  while p.cur.lexeme in ["<<", ">>"]:
    let op = p.cur.lexeme
    p.bump()
    result = binaryExpr(op, result, p.parseAddExpr())

proc parseRelationalExpr(p: var Parser): CExpr =
  result = p.parseShiftExpr()
  while p.cur.lexeme in ["<", "<=", ">", ">="]:
    let op = p.cur.lexeme
    p.bump()
    result = binaryExpr(op, result, p.parseShiftExpr())

proc parseEqualityExpr(p: var Parser): CExpr =
  result = p.parseRelationalExpr()
  while p.cur.lexeme in ["==", "!="]:
    let op = p.cur.lexeme
    p.bump()
    result = binaryExpr(op, result, p.parseRelationalExpr())

proc parseBitAndExpr(p: var Parser): CExpr =
  result = p.parseEqualityExpr()
  while p.consume("&"):
    result = binaryExpr("&", result, p.parseEqualityExpr())

proc parseBitXorExpr(p: var Parser): CExpr =
  result = p.parseBitAndExpr()
  while p.consume("^"):
    result = binaryExpr("^", result, p.parseBitAndExpr())

proc parseBitOrExpr(p: var Parser): CExpr =
  result = p.parseBitXorExpr()
  while p.consume("|"):
    result = binaryExpr("|", result, p.parseBitXorExpr())

proc parseLogAndExpr(p: var Parser): CExpr =
  result = p.parseBitOrExpr()
  while p.consume("&&"):
    result = binaryExpr("&&", result, p.parseBitOrExpr())

proc parseLogOrExpr(p: var Parser): CExpr =
  result = p.parseLogAndExpr()
  while p.consume("||"):
    result = binaryExpr("||", result, p.parseLogAndExpr())

proc parseConditionalExpr(p: var Parser): CExpr =
  result = p.parseLogOrExpr()
  if p.consume("?"):
    let thenExpr = p.parseConstExpr()
    p.expect(":")
    result = conditionalExpr(result, thenExpr, p.parseConditionalExpr())

proc parseConstExpr(p: var Parser): CExpr =
  p.parseConditionalExpr()

proc parseTypeofSpecifier(p: var Parser): CType =
  p.expect("(")
  if p.isTypeNameStart():
    result = p.parseTypeName()
  else:
    raise p.fail("typeof(expr) is not implemented yet")
  p.expect(")")

proc mapBuiltin(counterVoid, counterBool, counterChar, counterShort, counterInt,
                counterLong, counterFloat, counterDouble: int;
                seenSigned, seenUnsigned: bool): CType =
  if counterVoid == 1:
    return builtinType(btVoid)
  if counterBool == 1:
    return builtinType(btBool)
  if counterFloat == 1:
    return builtinType(btFloat)
  if counterDouble == 1 and counterLong == 1:
    return builtinType(btLongDouble)
  if counterDouble == 1:
    return builtinType(btDouble)
  if counterChar == 1:
    if seenUnsigned: return builtinType(btUChar)
    if seenSigned: return builtinType(btSChar)
    return builtinType(btChar)
  if counterShort == 1:
    if seenUnsigned: return builtinType(btUShort)
    return builtinType(btShort)
  if counterLong >= 2:
    if seenUnsigned: return builtinType(btULongLong)
    return builtinType(btLongLong)
  if counterLong == 1:
    if seenUnsigned: return builtinType(btULong)
    return builtinType(btLong)
  if seenUnsigned:
    return builtinType(btUInt)
  if counterInt in {0, 1}:
    return builtinType(btInt)
  raise newException(CParseError, "invalid builtin type combination")

proc parseEnumSpecifier(p: var Parser): CType
proc parseStructOrUnion(p: var Parser; kind: CTypeKind): CType
proc parseDeclSpec(p: var Parser; allowStorage: bool): CDeclSpec
proc parseDeclarator(p: var Parser; base: CType): CDecl
proc parseAbstractDeclarator(p: var Parser; base: CType): CType
proc parseTypeSuffix(p: var Parser; base: CType): CType

proc parseDeclSpec(p: var Parser; allowStorage: bool): CDeclSpec =
  result = CDeclSpec(storage: {}, callConv: ccNone, qualifiers: {}, baseType: nil)
  var counterVoid = 0
  var counterBool = 0
  var counterChar = 0
  var counterShort = 0
  var counterInt = 0
  var counterLong = 0
  var counterFloat = 0
  var counterDouble = 0
  var seenSigned = false
  var seenUnsigned = false
  var sawOther = false

  while true:
    if p.skipAttribute():
      continue

    case p.cur.lexeme
    of "typedef", "extern", "static", "inline", "_Thread_local", "__thread":
      if not allowStorage:
        raise p.fail("storage class specifier is not allowed here")
      case p.cur.lexeme
      of "typedef":
        result.storage.incl scTypedef
      of "extern":
        result.storage.incl scExtern
      of "static":
        result.storage.incl scStatic
      of "inline":
        result.storage.incl scInline
      else:
        result.storage.incl scThreadLocal
      p.bump()
    of "__cdecl", "__stdcall", "__fastcall", "__vectorcall":
      result.callConv = callConvFromLexeme(p.cur.lexeme)
      p.bump()
    of "const":
      result.qualifiers.incl cqConst
      p.bump()
    of "volatile", "__volatile__":
      result.qualifiers.incl cqVolatile
      p.bump()
    of "restrict", "__restrict", "__restrict__":
      result.qualifiers.incl cqRestrict
      p.bump()
    of "_Atomic":
      result.qualifiers.incl cqAtomic
      p.bump()
      if p.at("(") and not sawOther and not (counterVoid + counterBool + counterChar +
          counterShort + counterInt + counterLong + counterFloat + counterDouble > 0):
        p.bump()
        let nested = p.parseDeclSpec(false)
        result.baseType = nested.baseType
        result.baseType.qualifiers.incl cqAtomic
        p.expect(")")
        sawOther = true
    of "_Alignas":
      p.bump()
      p.skipBalanced("(", ")")
    of "struct":
      if sawOther or counterVoid + counterBool + counterChar + counterShort +
          counterInt + counterLong + counterFloat + counterDouble > 0:
        break
      p.bump()
      result.baseType = p.parseStructOrUnion(ctStruct)
      sawOther = true
    of "union":
      if sawOther or counterVoid + counterBool + counterChar + counterShort +
          counterInt + counterLong + counterFloat + counterDouble > 0:
        break
      p.bump()
      result.baseType = p.parseStructOrUnion(ctUnion)
      sawOther = true
    of "enum":
      if sawOther or counterVoid + counterBool + counterChar + counterShort +
          counterInt + counterLong + counterFloat + counterDouble > 0:
        break
      p.bump()
      result.baseType = p.parseEnumSpecifier()
      sawOther = true
    of "typeof", "__typeof__":
      if sawOther or counterVoid + counterBool + counterChar + counterShort +
          counterInt + counterLong + counterFloat + counterDouble > 0:
        break
      p.bump()
      result.baseType = p.parseTypeofSpecifier()
      sawOther = true
    of "void":
      inc counterVoid
      p.bump()
    of "_Bool":
      inc counterBool
      p.bump()
    of "char":
      inc counterChar
      p.bump()
    of "short":
      inc counterShort
      p.bump()
    of "int":
      inc counterInt
      p.bump()
    of "long":
      inc counterLong
      p.bump()
    of "float":
      inc counterFloat
      p.bump()
    of "double":
      inc counterDouble
      p.bump()
    of "signed":
      seenSigned = true
      p.bump()
    of "unsigned":
      seenUnsigned = true
      p.bump()
    else:
      if p.cur.kind == tkIdent and p.cur.lexeme in p.typedefNames and not sawOther and
          counterVoid + counterBool + counterChar + counterShort + counterInt +
          counterLong + counterFloat + counterDouble == 0:
        result.baseType = namedType(p.cur.lexeme)
        p.bump()
        sawOther = true
      else:
        break

  if result.baseType.isNil:
    result.baseType = mapBuiltin(counterVoid, counterBool, counterChar, counterShort,
      counterInt, counterLong, counterFloat, counterDouble, seenSigned, seenUnsigned)
  result.baseType.qualifiers.incl result.qualifiers

proc parsePointerQualifiers(p: var Parser): CTypeQuals =
  result = {}
  while true:
    case p.cur.lexeme
    of "const":
      result.incl cqConst
      p.bump()
    of "volatile", "__volatile__":
      result.incl cqVolatile
      p.bump()
    of "restrict", "__restrict", "__restrict__":
      result.incl cqRestrict
      p.bump()
    of "_Atomic":
      result.incl cqAtomic
      p.bump()
    else:
      break

proc parsePointers(p: var Parser; base: CType): CType =
  result = base
  while p.consume("*"):
    result = pointerType(result, p.parsePointerQualifiers())

proc parseFunctionParams(p: var Parser; returnType: CType): CType =
  var params: seq[CDecl] = @[]
  var isVariadic = false

  if p.at("void") and p.peek().lexeme == ")":
    p.bump()
    p.expect(")")
    return functionType(returnType, @[], false)

  while not p.at(")"):
    if params.len > 0:
      p.expect(",")
    if p.consume("..."):
      isVariadic = true
      break

    let spec = p.parseDeclSpec(false)
    var param = if p.at(",") or p.at(")"):
      CDecl(name: "", storage: spec.storage, callConv: spec.callConv, typ: spec.baseType)
    else:
      p.parseDeclarator(spec.baseType)
    param.storage = spec.storage
    if param.callConv == ccNone:
      param.callConv = spec.callConv
    param.typ = applyCallConv(param.typ, param.callConv)
    params.add param

  p.expect(")")
  result = functionType(returnType, params, isVariadic)

proc parseArrayDimensions(p: var Parser; elem: CType): CType =
  while p.cur.lexeme in ["static", "const", "volatile", "restrict", "__restrict",
                         "__restrict__"]:
    p.bump()
  let lenExpr = if p.at("]"): nil else: p.parseConstExpr()
  p.expect("]")
  result = arrayType(elem, lenExpr)

proc parseTypeSuffix(p: var Parser; base: CType): CType =
  result = base
  while true:
    if p.consume("("):
      result = p.parseFunctionParams(result)
    elif p.consume("["):
      result = p.parseArrayDimensions(result)
    else:
      break

proc parseAbstractDeclarator(p: var Parser; base: CType): CType =
  let withPointers = p.parsePointers(base)

  if p.consume("("):
    let innerPos = p.pos
    discard p.parseAbstractDeclarator(namedType("__dummy"))
    p.expect(")")
    let withSuffix = p.parseTypeSuffix(withPointers)
    let restPos = p.pos
    p.pos = innerPos
    result = p.parseAbstractDeclarator(withSuffix)
    p.pos = restPos
    return

  result = p.parseTypeSuffix(withPointers)

proc parseTypeName(p: var Parser): CType =
  let spec = p.parseDeclSpec(false)
  result = spec.baseType
  if p.cur.lexeme == "*" or p.cur.lexeme == "(" or p.cur.lexeme == "[" or
      callConvFromLexeme(p.cur.lexeme) != ccNone:
    let decl = p.parseDeclarator(spec.baseType)
    if decl.name.len != 0:
      raise p.fail("type name cannot contain an identifier")
    result = decl.typ
  result = applyCallConv(result, spec.callConv)

proc parseDeclarator(p: var Parser; base: CType): CDecl =
  result = CDecl(name: "", storage: {}, callConv: ccNone, typ: nil)
  while callConvFromLexeme(p.cur.lexeme) != ccNone:
    result.callConv = callConvFromLexeme(p.cur.lexeme)
    p.bump()

  let withPointers = p.parsePointers(base)

  if p.consume("("):
    let innerPos = p.pos
    discard p.parseDeclarator(namedType("__dummy"))
    p.expect(")")
    let withSuffix = p.parseTypeSuffix(withPointers)
    let restPos = p.pos
    p.pos = innerPos
    result = p.parseDeclarator(withSuffix)
    p.pos = restPos
    return

  if p.cur.kind in {tkIdent, tkKeyword} and p.cur.lexeme notin [
      "const", "volatile", "restrict", "__restrict", "__restrict__", "_Atomic"]:
    result.name = p.cur.lexeme
    p.bump()
  while callConvFromLexeme(p.cur.lexeme) != ccNone:
    result.callConv = callConvFromLexeme(p.cur.lexeme)
    p.bump()
    if result.name.len == 0 and p.cur.kind in {tkIdent, tkKeyword}:
      result.name = p.cur.lexeme
      p.bump()
  result.typ = p.parseTypeSuffix(withPointers)
  result.typ = applyCallConv(result.typ, result.callConv)

proc parseStructFields(p: var Parser): seq[CDecl] =
  result = @[]
  while not p.at("}"):
    let spec = p.parseDeclSpec(false)
    if p.consume(";"):
      result.add CDecl(name: "", storage: spec.storage, callConv: spec.callConv,
                       typ: applyCallConv(spec.baseType, spec.callConv))
      continue
    while true:
      var field = p.parseDeclarator(spec.baseType)
      field.storage = spec.storage
      if field.callConv == ccNone:
        field.callConv = spec.callConv
      field.typ = applyCallConv(field.typ, field.callConv)
      result.add field
      if not p.consume(","):
        break
    p.expect(";")

proc parseStructOrUnion(p: var Parser; kind: CTypeKind): CType =
  result = nil
  var tag = ""
  if p.cur.kind in {tkIdent, tkKeyword}:
    tag = p.cur.lexeme
    p.bump()

  let key = if tag.len == 0: "" else: tagKey(kind, tag)
  if not p.consume("{"):
    if key.len != 0 and key in p.tagTypes:
      return p.tagTypes[key]
    result = if kind == ctStruct: structType(tag = tag) else: unionType(tag = tag)
    if key.len != 0:
      p.tagTypes[key] = result
    return

  result = if kind == ctStruct: structType(tag = tag) else: unionType(tag = tag)
  result.fields = p.parseStructFields()
  p.expect("}")
  result.isComplete = true
  if key.len != 0:
    p.tagTypes[key] = result

proc parseEnumSpecifier(p: var Parser): CType =
  result = nil
  var tag = ""
  if p.cur.kind in {tkIdent, tkKeyword}:
    tag = p.cur.lexeme
    p.bump()

  let key = if tag.len == 0: "" else: tagKey(ctEnum, tag)
  if not p.consume("{"):
    if key.len != 0 and key in p.tagTypes:
      return p.tagTypes[key]
    result = enumType(tag = tag)
    if key.len != 0:
      p.tagTypes[key] = result
    return

  result = enumType(tag = tag)
  while not p.at("}"):
    if result.items.len > 0:
      p.expect(",")
      if p.at("}"):
        break
    let name = p.takeIdent()
    var valueExpr: CExpr = nil
    if p.consume("="):
      valueExpr = p.parseConstExpr()
    result.items.add CEnumItem(name: name, valueExpr: valueExpr)
  p.expect("}")
  result.isComplete = true
  if key.len != 0:
    p.tagTypes[key] = result

proc skipInitializer(p: var Parser) =
  if not p.consume("="):
    return
  discard p.collectUntilTopLevel({',', ';'})

proc parseTopLevelDecls*(source: string): seq[CDecl] =
  result = @[]
  var p = initParser(source)
  while not p.atKind(tkEof):
    let spec = p.parseDeclSpec(true)
    if p.consume(";"):
      result.add CDecl(name: "", storage: spec.storage, callConv: spec.callConv,
                       typ: applyCallConv(spec.baseType, spec.callConv))
      continue

    while true:
      var decl = p.parseDeclarator(spec.baseType)
      decl.storage = spec.storage
      if decl.callConv == ccNone:
        decl.callConv = spec.callConv
      decl.typ = applyCallConv(decl.typ, decl.callConv)
      result.add decl
      if scTypedef in decl.storage and decl.name.len > 0:
        p.typedefNames.incl decl.name
      p.skipInitializer()
      if not p.consume(","):
        break
    p.expect(";")

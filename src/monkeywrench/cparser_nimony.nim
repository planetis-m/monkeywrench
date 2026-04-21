# Lower the lightweight C AST into Nimony-facing NIF trees.

import std/[strutils, tables]
import cparser_ast, cparser
import ../../../src/nimony/lib/nimonyplugins

type
  NimonyBindingsConfig* = object
    header*: string
    exportSymbols*: bool
    originInfo*: LineInfo

  LoweringContext = object
    header: string
    exportSymbols: bool
    info: LineInfo
    constValues: Table[string, BiggestInt]

proc renderNimonyBindings*(
    decls: seq[CDecl];
    config: NimonyBindingsConfig
): NifBuilder
proc parseCBindingsToNimony*(
    source: string;
    config: NimonyBindingsConfig
): NifBuilder

func initLoweringContext(config: NimonyBindingsConfig): LoweringContext =
  LoweringContext(
    header: config.header,
    exportSymbols: config.exportSymbols,
    info: config.originInfo,
    constValues: initTable[string, BiggestInt]()
  )

proc exportedMarker(t: var NifBuilder; ctx: LoweringContext) =
  if ctx.exportSymbols:
    t.addIdent "*"
  else:
    t.addEmptyNode()

proc addCallConvPragma(t: var NifBuilder; cc: CCallConv; info: LineInfo) =
  case cc
  of ccNone:
    discard
  of ccCdecl:
    t.addParLe("cdecl", info)
    t.addParRi()
  of ccStdcall:
    t.addParLe("stdcall", info)
    t.addParRi()
  of ccFastcall:
    t.addParLe("fastcall", info)
    t.addParRi()
  of ccVectorcall:
    discard "not implemented"

proc addImportPragmas(t: var NifBuilder; cName, header: string; info: LineInfo;
                      bycopy = false; callConv = ccNone) =
  t.withTree PragmasS, info:
    if bycopy:
      t.withTree BycopyP, info: discard
    t.withTree ImportcP, info:
      t.addStrLit cName
    if header.len > 0:
      t.withTree HeaderP, info:
        t.addStrLit header
    t.addCallConvPragma(callConv, info)

proc bitsForBuiltin(bt: CBuiltinType): int =
  case bt
  of btVoid: 0
  of btBool: 1
  of btChar, btSChar, btUChar: 8
  of btShort, btUShort: 16
  of btInt, btUInt, btFloat: 32
  of btLong, btULong, btDouble: 64
  of btLongLong, btULongLong: 64
  of btLongDouble: 80

proc appendType(t: var NifBuilder; typ: CType; ctx: var LoweringContext)

func isProcPointerTypedef(typ: CType): bool =
  typ.kind == ctPointer and not typ.base.isNil and typ.base.kind == ctFunction

proc parseNumberLiteral(raw: string; context: string): tuple[value: uint64, isUnsigned: bool] =
  result = (0'u64, false)
  let text = raw.strip()
  if text.len == 0:
    raise newException(ValueError, "empty numeric literal for " & context)

  var endPos = text.len
  while endPos > 0 and text[endPos - 1] in {'u', 'U', 'l', 'L'}:
    dec endPos
  if endPos == 0:
    raise newException(ValueError, "invalid numeric literal for " & context & ": " & text)

  let digits = text[0 ..< endPos]
  let suffix = text[endPos .. ^1]
  let isUnsigned = suffix.contains({'u', 'U'})

  if digits.len >= 2 and digits[0] == '0' and digits[1] in {'x', 'X'}:
    result.value = parseHexInt(digits[2 .. ^1]).uint64
  elif digits.len > 1 and digits[0] == '0':
    result.value = parseOctInt(digits[1 .. ^1]).uint64
  else:
    result.value = parseBiggestUInt(digits).uint64
  result.isUnsigned = isUnsigned

proc parseCharLiteral(raw: string): uint64 =
  if raw.len < 2 or raw[0] != '\'' or raw[^1] != '\'':
    raise newException(ValueError, "invalid character literal: " & raw)

  let body = raw[1 .. ^2]
  if body.len == 0:
    raise newException(ValueError, "empty character literal")

  if body[0] != '\\':
    if body.len != 1:
      raise newException(ValueError, "multi-character literals are not supported: " & raw)
    return uint64(ord(body[0]))

  if body.len == 1:
    raise newException(ValueError, "invalid escape sequence in character literal: " & raw)

  case body[1]
  of '\'', '"', '?', '\\':
    result = uint64(ord(body[1]))
  of 'a':
    result = uint64(ord('\a'))
  of 'b':
    result = uint64(ord('\b'))
  of 'f':
    result = uint64(ord('\f'))
  of 'n':
    result = uint64(ord('\n'))
  of 'r':
    result = uint64(ord('\r'))
  of 't':
    result = uint64(ord('\t'))
  of 'v':
    result = uint64(ord('\v'))
  of 'x':
    if body.len <= 2:
      raise newException(ValueError, "missing hex digits in character literal: " & raw)
    result = parseHexInt(body[2 .. ^1]).uint64
  of '0'..'7':
    var last = 1
    while last + 1 < body.len and last < 3 and body[last + 1] in {'0'..'7'}:
      inc last
    result = parseOctInt(body[1 .. last]).uint64
  else:
    raise newException(ValueError, "unsupported character escape in literal: " & raw)

proc appendExpr(
    t: var NifBuilder;
    expr: CExpr;
    ctx: var LoweringContext
)

proc tryEvalConstExpr(
    ctx: LoweringContext;
    expr: CExpr;
    value: var BiggestInt
): bool

proc tryEvalBinaryExpr(
    ctx: LoweringContext;
    op: string;
    left, right: CExpr;
    value: var BiggestInt
): bool =
  var a: BiggestInt
  var b: BiggestInt
  if not ctx.tryEvalConstExpr(left, a) or not ctx.tryEvalConstExpr(right, b):
    return false

  case op
  of "+":
    value = a + b
  of "-":
    value = a - b
  of "*":
    value = a * b
  of "/":
    if b == 0:
      return false
    value = a div b
  of "%":
    if b == 0:
      return false
    value = a mod b
  of "<<":
    if b < 0:
      return false
    value = a shl int(b)
  of ">>":
    if b < 0:
      return false
    value = a shr int(b)
  of "&":
    value = a and b
  of "|":
    value = a or b
  of "^":
    value = a xor b
  of "&&":
    value = if a != 0 and b != 0: 1 else: 0
  of "||":
    value = if a != 0 or b != 0: 1 else: 0
  of "==":
    value = if a == b: 1 else: 0
  of "!=":
    value = if a != b: 1 else: 0
  of "<=":
    value = if a <= b: 1 else: 0
  of "<":
    value = if a < b: 1 else: 0
  of ">=":
    value = if a >= b: 1 else: 0
  of ">":
    value = if a > b: 1 else: 0
  else:
    return false
  result = true

proc tryEvalConstExpr(
    ctx: LoweringContext;
    expr: CExpr;
    value: var BiggestInt
): bool =
  case expr.kind
  of ceNumber:
    let parsed = parseNumberLiteral(expr.number, "constant expression")
    value = cast[BiggestInt](parsed.value)
    result = true
  of ceChar:
    value = cast[BiggestInt](parseCharLiteral(expr.charLit))
    result = true
  of ceIdent:
    if expr.ident in ctx.constValues:
      value = ctx.constValues[expr.ident]
      result = true
    else:
      result = false
  of ceUnary:
    var a: BiggestInt
    if not ctx.tryEvalConstExpr(expr.operand, a):
      return false
    case expr.unaryOp
    of "+":
      value = a
    of "-":
      value = -a
    of "!":
      value = if a == 0: 1 else: 0
    of "~":
      value = not a
    else:
      return false
    result = true
  of ceBinary:
    result = ctx.tryEvalBinaryExpr(expr.binaryOp, expr.left, expr.right, value)
  of ceCast:
    result = ctx.tryEvalConstExpr(expr.castExpr, value)
  of ceConditional:
    var cond: BiggestInt
    if not ctx.tryEvalConstExpr(expr.condExpr, cond):
      return false
    if cond != 0:
      result = ctx.tryEvalConstExpr(expr.thenExpr, value)
    else:
      result = ctx.tryEvalConstExpr(expr.elseExpr, value)
  of ceSizeofExpr, ceSizeofType, ceAlignofType:
    result = false

proc appendBinaryExpr(
    t: var NifBuilder;
    op: string;
    left, right: CExpr;
    ctx: var LoweringContext
) =
  case op
  of "+":
    t.withTree AddX, ctx.info:
      t.appendExpr(left, ctx)
      t.appendExpr(right, ctx)
  of "-":
    t.withTree SubX, ctx.info:
      t.appendExpr(left, ctx)
      t.appendExpr(right, ctx)
  of "*":
    t.withTree MulX, ctx.info:
      t.appendExpr(left, ctx)
      t.appendExpr(right, ctx)
  of "/":
    t.withTree DivX, ctx.info:
      t.appendExpr(left, ctx)
      t.appendExpr(right, ctx)
  of "%":
    t.withTree ModX, ctx.info:
      t.appendExpr(left, ctx)
      t.appendExpr(right, ctx)
  of "<<":
    t.withTree ShlX, ctx.info:
      t.appendExpr(left, ctx)
      t.appendExpr(right, ctx)
  of ">>":
    t.withTree ShrX, ctx.info:
      t.appendExpr(left, ctx)
      t.appendExpr(right, ctx)
  of "&":
    t.withTree BitandX, ctx.info:
      t.appendExpr(left, ctx)
      t.appendExpr(right, ctx)
  of "|":
    t.withTree BitorX, ctx.info:
      t.appendExpr(left, ctx)
      t.appendExpr(right, ctx)
  of "^":
    t.withTree BitxorX, ctx.info:
      t.appendExpr(left, ctx)
      t.appendExpr(right, ctx)
  of "&&":
    t.withTree AndX, ctx.info:
      t.appendExpr(left, ctx)
      t.appendExpr(right, ctx)
  of "||":
    t.withTree OrX, ctx.info:
      t.appendExpr(left, ctx)
      t.appendExpr(right, ctx)
  of "==":
    t.withTree EqX, ctx.info:
      t.appendExpr(left, ctx)
      t.appendExpr(right, ctx)
  of "!=":
    t.withTree NeqX, ctx.info:
      t.appendExpr(left, ctx)
      t.appendExpr(right, ctx)
  of "<=":
    t.withTree LeX, ctx.info:
      t.appendExpr(left, ctx)
      t.appendExpr(right, ctx)
  of "<":
    t.withTree LtX, ctx.info:
      t.appendExpr(left, ctx)
      t.appendExpr(right, ctx)
  of ">=":
    t.withTree NotX, ctx.info:
      t.withTree LtX, ctx.info:
        t.appendExpr(left, ctx)
        t.appendExpr(right, ctx)
  of ">":
    t.withTree LtX, ctx.info:
      t.appendExpr(right, ctx)
      t.appendExpr(left, ctx)
  else:
    raise newException(ValueError, "unsupported binary operator: " & op)

proc appendExpr(
    t: var NifBuilder;
    expr: CExpr;
    ctx: var LoweringContext
) =
  var constValue: BiggestInt
  if ctx.tryEvalConstExpr(expr, constValue):
    t.addIntLit(constValue)
    return

  case expr.kind
  of ceNumber:
    let parsed = parseNumberLiteral(expr.number, "numeric literal")
    if parsed.isUnsigned:
      t.addUIntLit(parsed.value)
    else:
      t.addIntLit(cast[BiggestInt](parsed.value))
  of ceChar:
    t.addIntLit(cast[BiggestInt](parseCharLiteral(expr.charLit)))
  of ceIdent:
    t.addSymUse(expr.ident, ctx.info)
  of ceUnary:
    case expr.unaryOp
    of "+":
      t.appendExpr(expr.operand, ctx)
    of "-":
      t.withTree NegX, ctx.info:
        t.appendExpr(expr.operand, ctx)
    of "!":
      t.withTree NotX, ctx.info:
        t.appendExpr(expr.operand, ctx)
    of "~":
      t.withTree BitnotX, ctx.info:
        t.appendExpr(expr.operand, ctx)
    else:
      raise newException(ValueError, "unsupported unary operator: " & expr.unaryOp)
  of ceBinary:
    t.appendBinaryExpr(expr.binaryOp, expr.left, expr.right, ctx)
  of ceCast:
    t.withTree CastX, ctx.info:
      t.appendType(expr.targetType, ctx)
      t.appendExpr(expr.castExpr, ctx)
  of ceSizeofType:
    t.withTree SizeofX, ctx.info:
      t.appendType(expr.typeExpr, ctx)
  of ceConditional:
    raise newException(ValueError, "conditional operator is not supported in lowering yet")
  of ceSizeofExpr:
    raise newException(ValueError, "sizeof(expr) is not supported in lowering yet")
  of ceAlignofType:
    raise newException(ValueError, "_Alignof is not supported in lowering yet")

func shouldEmitDecl(decl: CDecl): bool =
  if scStatic in decl.storage:
    return false
  if decl.typ.kind == ctFunction and scInline in decl.storage and scExtern notin decl.storage:
    return false
  true

proc appendEnumField(
    t: var NifBuilder;
    item: CEnumItem;
    ctx: var LoweringContext;
    nextValue: var BiggestInt
) =
  t.withTree EfldU, ctx.info:
    t.addIdent(item.name)
    if ctx.exportSymbols:
      t.addIdent("x")
    else:
      t.addEmptyNode()
    t.addEmptyNode()
    t.addEmptyNode()
    if item.valueExpr.isNil:
      ctx.constValues[item.name] = nextValue
      t.addIntLit(nextValue)
      inc nextValue
    else:
      var constValue: BiggestInt
      if ctx.tryEvalConstExpr(item.valueExpr, constValue):
        ctx.constValues[item.name] = constValue
        t.addIntLit(constValue)
        nextValue = constValue + 1
      else:
        t.appendExpr(item.valueExpr, ctx)

proc appendEnumBody(
    t: var NifBuilder;
    items: seq[CEnumItem];
    ctx: var LoweringContext
) =
  var nextValue = 0.BiggestInt
  for item in items:
    t.appendEnumField(item, ctx, nextValue)

proc appendField(t: var NifBuilder; field: CDecl; ctx: var LoweringContext) =
  t.withTree FldU, ctx.info:
    t.addIdent(field.name)
    t.addEmptyNode()
    t.withTree PragmasS, ctx.info:
      t.withTree ImportcP, ctx.info:
        t.addStrLit(field.name)
    t.appendType(field.typ, ctx)
    t.addEmptyNode()

proc appendParam(
    t: var NifBuilder;
    param: CDecl;
    idx: int;
    ctx: var LoweringContext
) =
  let name = if param.name.len == 0: "a" & $idx else: param.name
  t.withTree ParamU, ctx.info:
    t.addIdent(name)
    t.addEmptyNode()
    if param.callConv != ccNone:
      t.withTree PragmasS, ctx.info:
        t.addCallConvPragma(param.callConv, ctx.info)
    else:
      t.addEmptyNode()
    t.appendType(param.typ, ctx)
    t.addEmptyNode()

proc appendParams(
    t: var NifBuilder;
    params: seq[CDecl];
    isVariadic: bool;
    ctx: var LoweringContext
) =
  t.withTree ParamsU, ctx.info:
    for i, param in params:
      t.appendParam(param, i, ctx)
    if isVariadic:
      t.withTree ParamU, ctx.info:
        t.addIdent("varargs")
        t.addEmptyNode()
        t.addEmptyNode()
        t.withTree VarargsT, ctx.info:
          t.addEmptyNode()
        t.addEmptyNode()

proc appendProcTypeBody(
    t: var NifBuilder;
    fn: CType;
    ctx: var LoweringContext
) =
  t.withTree ProctypeT, ctx.info:
    t.addEmptyNode()
    t.addEmptyNode()
    t.addEmptyNode()
    t.addEmptyNode()
    t.appendParams(fn.params, fn.isVariadic, ctx)
    if fn.returnType.kind == ctBuiltin and fn.returnType.builtin == btVoid:
      t.addEmptyNode()
    else:
      t.appendType(fn.returnType, ctx)
    t.withTree PragmasS, ctx.info:
      t.addCallConvPragma(fn.callConv, ctx.info)
    t.addEmptyNode()
    t.addEmptyNode()

proc appendBuiltinType(t: var NifBuilder; typ: CType; info: LineInfo) =
  case typ.builtin
  of btVoid:
    t.withTree VoidT, info: discard
  of btBool:
    t.withTree BoolT, info: discard
  of btChar:
    t.withTree CT, info:
      t.addIntLit(bitsForBuiltin(typ.builtin))
  of btFloat, btDouble, btLongDouble:
    t.withTree FT, info:
      t.addIntLit(bitsForBuiltin(typ.builtin))
  of btUChar, btUShort, btUInt, btULong, btULongLong:
    t.withTree UT, info:
      t.addIntLit(bitsForBuiltin(typ.builtin))
  else:
    t.withTree IT, info:
      t.addIntLit(bitsForBuiltin(typ.builtin))

proc appendType(t: var NifBuilder; typ: CType; ctx: var LoweringContext) =
  case typ.kind
  of ctBuiltin:
    t.appendBuiltinType(typ, ctx.info)
  of ctNamed:
    t.addSymUse(typ.name, ctx.info)
  of ctPointer:
    if typ.base.kind == ctBuiltin and typ.base.builtin == btChar:
      t.withTree CstringT, ctx.info: discard
    else:
      t.withTree PtrT, ctx.info:
        t.appendType(typ.base, ctx)
  of ctArray:
    t.withTree ArrayT, ctx.info:
      t.appendType(typ.elem, ctx)
      t.withTree RangetypeT, ctx.info:
        t.withTree IT, ctx.info:
          t.addIntLit(32)
        t.addIntLit(0)
        if typ.lenExpr.isNil:
          t.addIntLit(0)
        else:
          var arrayLen: BiggestInt
          if ctx.tryEvalConstExpr(typ.lenExpr, arrayLen):
            t.addIntLit(arrayLen - 1)
          else:
            raise newException(ValueError, "array length expression is not supported in lowering yet")
  of ctFunction:
    t.appendProcTypeBody(typ, ctx)
  of ctStruct, ctUnion:
    if typ.tagName.len > 0:
      t.addSymUse(typ.tagName, ctx.info)
    else:
      t.withTree ObjectT, ctx.info:
        t.addEmptyNode()
        for field in typ.fields:
          t.appendField(field, ctx)
  of ctEnum:
    if typ.tagName.len > 0:
      t.addSymUse(typ.tagName, ctx.info)
    else:
      t.withTree EnumT, ctx.info:
        t.withTree UT, ctx.info:
          t.addIntLit(32)
        t.appendEnumBody(typ.items, ctx)

proc appendTypeDecl(
    t: var NifBuilder;
    decl: CDecl;
    ctx: var LoweringContext
) =
  t.withTree TypeS, ctx.info:
    t.addIdent(decl.name)
    t.exportedMarker(ctx)
    t.addEmptyNode()
    if scTypedef in decl.storage and decl.typ.isProcPointerTypedef:
      t.addEmptyNode()
    elif scTypedef in decl.storage:
      t.addImportPragmas(decl.name, ctx.header, ctx.info)
    else:
      let cName =
        case decl.typ.kind
        of ctStruct: "struct " & decl.typ.tagName
        of ctUnion: "union " & decl.typ.tagName
        of ctEnum: "enum " & decl.typ.tagName
        else: decl.name
      t.addImportPragmas(
        cName,
        ctx.header,
        ctx.info,
        bycopy = decl.typ.kind in {ctStruct, ctUnion}
      )
    if scTypedef in decl.storage and decl.typ.isProcPointerTypedef:
      t.appendProcTypeBody(decl.typ.base, ctx)
    else:
      t.appendType(decl.typ, ctx)

proc appendStandaloneTaggedType(
    t: var NifBuilder;
    typ: CType;
    ctx: var LoweringContext
) =
  let name = typ.tagName
  t.withTree TypeS, ctx.info:
    t.addIdent(name)
    t.exportedMarker(ctx)
    t.addEmptyNode()
    let cName =
      case typ.kind
      of ctStruct: "struct " & name
      of ctUnion: "union " & name
      of ctEnum: "enum " & name
      else: name
    t.addImportPragmas(
      cName,
      ctx.header,
      ctx.info,
      bycopy = typ.kind in {ctStruct, ctUnion}
    )
    case typ.kind
    of ctStruct:
      t.withTree ObjectT, ctx.info:
        t.addEmptyNode()
        for field in typ.fields:
          t.appendField(field, ctx)
    of ctUnion:
      t.withTree ObjectT, ctx.info:
        t.addEmptyNode()
        t.addParLe("union", ctx.info)
        t.addParRi()
        for field in typ.fields:
          t.appendField(field, ctx)
    of ctEnum:
      t.withTree EnumT, ctx.info:
        t.withTree UT, ctx.info:
          t.addIntLit(32)
        t.appendEnumBody(typ.items, ctx)
    else:
      t.appendType(typ, ctx)

proc appendProcDecl(
    t: var NifBuilder;
    decl: CDecl;
    ctx: var LoweringContext
) =
  assert decl.typ.kind == ctFunction
  t.withTree ProcS, ctx.info:
    t.addIdent(decl.name)
    t.exportedMarker(ctx)
    t.addEmptyNode()
    t.addEmptyNode()
    t.appendParams(decl.typ.params, decl.typ.isVariadic, ctx)
    t.appendType(decl.typ.returnType, ctx)
    t.addImportPragmas(
      decl.name,
      ctx.header,
      ctx.info,
      callConv = decl.typ.callConv
    )
    t.addEmptyNode()
    t.addEmptyNode()

proc appendVarDecl(
    t: var NifBuilder;
    decl: CDecl;
    ctx: var LoweringContext
) =
  t.withTree GvarS, ctx.info:
    t.addIdent(decl.name)
    t.exportedMarker(ctx)
    t.addImportPragmas(decl.name, ctx.header, ctx.info)
    t.appendType(decl.typ, ctx)
    t.addEmptyNode()

proc renderNimonyBindings*(decls: seq[CDecl]; config: NimonyBindingsConfig): NifBuilder =
  var ctx = initLoweringContext(config)
  result = createTree()
  result.withTree StmtsS, ctx.info:
    var seenTagged: seq[string] = @[]
    for decl in decls:
      if not shouldEmitDecl(decl):
        discard
      elif decl.name.len == 0:
        if decl.typ.kind in {ctStruct, ctUnion, ctEnum} and
            decl.typ.tagName.len > 0 and decl.typ.isComplete and
            decl.typ.tagName notin seenTagged:
          seenTagged.add decl.typ.tagName
          result.appendStandaloneTaggedType(decl.typ, ctx)
      elif scTypedef in decl.storage:
        result.appendTypeDecl(decl, ctx)
      elif decl.typ.kind == ctFunction:
        result.appendProcDecl(decl, ctx)
      else:
        result.appendVarDecl(decl, ctx)

proc parseCBindingsToNimony*(source: string; config: NimonyBindingsConfig): NifBuilder =
  try:
    result = renderNimonyBindings(parseTopLevelDecls(source), config)
  except CatchableError as e:
    result = errorTree(e.msg)

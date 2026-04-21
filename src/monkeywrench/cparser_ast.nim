# Lightweight C parser AST for bindings generation.
#
# The goal is not full C semantic modeling. This layer captures enough shape
# for top-level declarations and declarators so a later lowering step can
# emit Nim/NIF bindings.

import std/[sequtils, strutils]

type
  CTokenKind* = enum
    tkIdent, tkKeyword, tkNumber, tkString, tkChar, tkPunct, tkEof

  CToken* = object
    kind*: CTokenKind
    lexeme*: string
    line*: int
    col*: int

  CTypeQual* = enum
    cqConst, cqVolatile, cqRestrict, cqAtomic

  CTypeQuals* = set[CTypeQual]

  CStorageClass* = enum
    scNone, scTypedef, scExtern, scStatic, scInline, scThreadLocal

  CStorageClasses* = set[CStorageClass]

  CCallConv* = enum
    ccNone, ccCdecl, ccStdcall, ccFastcall, ccVectorcall

  CBuiltinType* = enum
    btVoid, btBool,
    btChar, btSChar, btUChar,
    btShort, btUShort,
    btInt, btUInt,
    btLong, btULong,
    btLongLong, btULongLong,
    btFloat, btDouble, btLongDouble

  CTypeKind* = enum
    ctBuiltin, ctNamed, ctPointer, ctArray, ctFunction, ctStruct, ctUnion, ctEnum

  CExprKind* = enum
    ceNumber, ceChar, ceIdent, ceUnary, ceBinary, ceConditional, ceCast,
    ceSizeofExpr, ceSizeofType, ceAlignofType

  CExpr* = ref object
    case kind*: CExprKind
    of ceNumber:
      number*: string
    of ceChar:
      charLit*: string
    of ceIdent:
      ident*: string
    of ceUnary:
      unaryOp*: string
      operand*: CExpr
    of ceBinary:
      binaryOp*: string
      left*, right*: CExpr
    of ceConditional:
      condExpr*: CExpr
      thenExpr*: CExpr
      elseExpr*: CExpr
    of ceCast:
      targetType*: CType
      castExpr*: CExpr
    of ceSizeofExpr:
      sizeofExpr*: CExpr
    of ceSizeofType, ceAlignofType:
      typeExpr*: CType

  CEnumItem* = object
    name*: string
    valueExpr*: CExpr

  CDecl* = object
    name*: string
    storage*: CStorageClasses
    callConv*: CCallConv
    typ*: CType

  CType* = ref object
    qualifiers*: CTypeQuals
    tagName*: string
    isComplete*: bool
    case kind*: CTypeKind
    of ctBuiltin:
      builtin*: CBuiltinType
    of ctNamed:
      name*: string
    of ctPointer:
      base*: CType
    of ctArray:
      elem*: CType
      lenExpr*: CExpr
    of ctFunction:
      returnType*: CType
      params*: seq[CDecl]
      isVariadic*: bool
      callConv*: CCallConv
    of ctStruct, ctUnion:
      fields*: seq[CDecl]
    of ctEnum:
      items*: seq[CEnumItem]

proc builtinType*(kind: CBuiltinType): CType =
  CType(kind: ctBuiltin, builtin: kind)

proc namedType*(name: string): CType =
  CType(kind: ctNamed, name: name)

proc pointerType*(base: CType; qualifiers: CTypeQuals = {}): CType =
  CType(kind: ctPointer, base: base, qualifiers: qualifiers)

proc arrayType*(elem: CType; lenExpr: CExpr = nil): CType =
  CType(kind: ctArray, elem: elem, lenExpr: lenExpr)

proc functionType*(returnType: CType; params: seq[CDecl]; isVariadic = false): CType =
  CType(kind: ctFunction, returnType: returnType, params: params, isVariadic: isVariadic,
        callConv: ccNone)

proc structType*(tag = ""; fields: seq[CDecl] = @[]; isComplete = false): CType =
  CType(kind: ctStruct, tagName: tag, fields: fields, isComplete: isComplete)

proc unionType*(tag = ""; fields: seq[CDecl] = @[]; isComplete = false): CType =
  CType(kind: ctUnion, tagName: tag, fields: fields, isComplete: isComplete)

proc enumType*(tag = ""; items: seq[CEnumItem] = @[]; isComplete = false): CType =
  CType(kind: ctEnum, tagName: tag, items: items, isComplete: isComplete)

proc numberExpr*(number: string): CExpr =
  CExpr(kind: ceNumber, number: number)

proc charExpr*(charLit: string): CExpr =
  CExpr(kind: ceChar, charLit: charLit)

proc identExpr*(ident: string): CExpr =
  CExpr(kind: ceIdent, ident: ident)

proc unaryExpr*(op: string; operand: CExpr): CExpr =
  CExpr(kind: ceUnary, unaryOp: op, operand: operand)

proc binaryExpr*(op: string; left, right: CExpr): CExpr =
  CExpr(kind: ceBinary, binaryOp: op, left: left, right: right)

proc conditionalExpr*(condExpr, thenExpr, elseExpr: CExpr): CExpr =
  CExpr(kind: ceConditional, condExpr: condExpr, thenExpr: thenExpr, elseExpr: elseExpr)

proc castExpr*(targetType: CType; castExpr: CExpr): CExpr =
  CExpr(kind: ceCast, targetType: targetType, castExpr: castExpr)

proc sizeofExpr*(expr: CExpr): CExpr =
  CExpr(kind: ceSizeofExpr, sizeofExpr: expr)

proc sizeofTypeExpr*(typ: CType): CExpr =
  CExpr(kind: ceSizeofType, typeExpr: typ)

proc alignofTypeExpr*(typ: CType): CExpr =
  CExpr(kind: ceAlignofType, typeExpr: typ)

proc storageName(storage: CStorageClass): string =
  case storage
  of scNone: ""
  of scTypedef: "typedef"
  of scExtern: "extern"
  of scStatic: "static"
  of scInline: "inline"
  of scThreadLocal: "_Thread_local"

proc `$`*(storage: CStorageClasses): string =
  var parts: seq[string] = @[]
  if scTypedef in storage:
    parts.add storageName(scTypedef)
  if scExtern in storage:
    parts.add storageName(scExtern)
  if scStatic in storage:
    parts.add storageName(scStatic)
  if scInline in storage:
    parts.add storageName(scInline)
  if scThreadLocal in storage:
    parts.add storageName(scThreadLocal)
  result = parts.join(" ")

proc `$`*(kind: CBuiltinType): string =
  case kind
  of btVoid: "void"
  of btBool: "_Bool"
  of btChar: "char"
  of btSChar: "signed char"
  of btUChar: "unsigned char"
  of btShort: "short"
  of btUShort: "unsigned short"
  of btInt: "int"
  of btUInt: "unsigned int"
  of btLong: "long"
  of btULong: "unsigned long"
  of btLongLong: "long long"
  of btULongLong: "unsigned long long"
  of btFloat: "float"
  of btDouble: "double"
  of btLongDouble: "long double"

proc `$`*(cc: CCallConv): string =
  case cc
  of ccNone: ""
  of ccCdecl: "cdecl"
  of ccStdcall: "stdcall"
  of ccFastcall: "fastcall"
  of ccVectorcall: "vectorcall"

proc renderQualifiers(quals: CTypeQuals): string =
  var parts: seq[string] = @[]
  if cqConst in quals: parts.add "const"
  if cqVolatile in quals: parts.add "volatile"
  if cqRestrict in quals: parts.add "restrict"
  if cqAtomic in quals: parts.add "_Atomic"
  result = parts.join(" ")

proc renderBaseType(typ: CType): string =
  let core = case typ.kind
  of ctBuiltin:
    $typ.builtin
  of ctNamed:
    typ.name
  of ctStruct:
    if typ.tagName.len == 0: "struct"
    else: "struct " & typ.tagName
  of ctUnion:
    if typ.tagName.len == 0: "union"
    else: "union " & typ.tagName
  of ctEnum:
    if typ.tagName.len == 0: "enum"
    else: "enum " & typ.tagName
  else:
    raise newException(ValueError, "renderBaseType expects a base type")
  let quals = renderQualifiers(typ.qualifiers)
  if quals.len == 0: core else: quals & " " & core

proc renderParam(decl: CDecl): string
proc renderExpr*(expr: CExpr): string
proc renderType*(typ: CType): string

proc renderDeclarator(typ: CType; name: string): string =
  case typ.kind
  of ctPointer:
    var inner = if name.len == 0: "*"
                else: "*" & name
    if typ.base.kind in {ctArray, ctFunction}:
      inner = "(" & inner & ")"
    if typ.qualifiers != {}:
      let quals = renderQualifiers(typ.qualifiers)
      if inner == "*":
        inner.add quals
      else:
        inner.insert(" " & quals, 1)
    renderDeclarator(typ.base, inner)
  of ctArray:
    let suffix =
      if typ.lenExpr.isNil:
        "[]"
      else:
        "[" & renderExpr(typ.lenExpr) & "]"
    renderDeclarator(typ.elem, name & suffix)
  of ctFunction:
    var parts = typ.params.mapIt(renderParam(it))
    if typ.isVariadic:
      parts.add "..."
    renderDeclarator(typ.returnType, name & "(" & parts.join(", ") & ")")
  else:
    let base = renderBaseType(typ)
    if name.len == 0: base else: base & " " & name

proc renderParam(decl: CDecl): string =
  renderDeclarator(decl.typ, decl.name)

proc renderExpr*(expr: CExpr): string =
  case expr.kind
  of ceNumber:
    expr.number
  of ceChar:
    expr.charLit
  of ceIdent:
    expr.ident
  of ceUnary:
    expr.unaryOp & renderExpr(expr.operand)
  of ceBinary:
    "(" & renderExpr(expr.left) & " " & expr.binaryOp & " " &
      renderExpr(expr.right) & ")"
  of ceConditional:
    "(" & renderExpr(expr.condExpr) & " ? " & renderExpr(expr.thenExpr) &
      " : " & renderExpr(expr.elseExpr) & ")"
  of ceCast:
    "(" & renderType(expr.targetType) & ")" & renderExpr(expr.castExpr)
  of ceSizeofExpr:
    "sizeof(" & renderExpr(expr.sizeofExpr) & ")"
  of ceSizeofType:
    "sizeof(" & renderType(expr.typeExpr) & ")"
  of ceAlignofType:
    "_Alignof(" & renderType(expr.typeExpr) & ")"

proc renderType*(typ: CType): string =
  renderDeclarator(typ, "")

proc renderDecl*(decl: CDecl): string =
  let head = renderDeclarator(decl.typ, decl.name)
  if decl.storage == {}:
    head
  else:
    $decl.storage & " " & head

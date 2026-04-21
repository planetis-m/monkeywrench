# Porting Handoff

This document is meant for the next coding agent. It points at the current implementation with function names and line numbers inside this repo so work can resume immediately.

## Files and hot spots

### `src/monkeywrench/cparser_ast.nim`

- `CExprKind` and `CExpr`: lines 44-72
- AST constructors:
  - `numberExpr`: lines 133-134
  - `charExpr`: lines 136-137
  - `identExpr`: lines 139-140
  - `unaryExpr`: lines 142-143
  - `binaryExpr`: lines 145-146
  - `conditionalExpr`: lines 148-149
  - `castExpr`: lines 151-152
  - `sizeofExpr`: lines 154-155
  - `sizeofTypeExpr`: lines 157-158
  - `alignofTypeExpr`: lines 160-161
- Declarator rendering:
  - `renderDeclarator`: lines 245-273
  - `renderType`: lines 303-304
  - `renderDecl`: lines 306-311
- Expression rendering:
  - `renderExpr`: lines 278-301

### `src/monkeywrench/cparser_lexer.nim`

- `isKeyword`: lines 21-30
- `tokenizeC`: lines 35-136

### `src/monkeywrench/cparser.nim`

- parser setup:
  - `initParser`: lines 28-30
  - `fail`: lines 35-38
  - `skipAttribute`: lines 103-120
- expression parsing:
  - `isTypeNameStart`: lines 169-178
  - `isTypeNameAhead`: lines 180-191
  - `parsePrimaryExpr`: lines 193-209
  - `parseUnaryExpr`: lines 211-231
  - `parseCastExpr`: lines 233-240
  - `parseMulExpr`: lines 242-247
  - `parseAddExpr`: lines 249-254
  - `parseShiftExpr`: lines 256-261
  - `parseRelationalExpr`: lines 263-268
  - `parseEqualityExpr`: lines 270-275
  - `parseBitAndExpr`: lines 277-280
  - `parseBitXorExpr`: lines 282-285
  - `parseBitOrExpr`: lines 287-290
  - `parseLogAndExpr`: lines 292-295
  - `parseLogOrExpr`: lines 297-300
  - `parseConditionalExpr`: lines 302-307
  - `parseConstExpr`: lines 309-310
- declaration specifiers:
  - `mapBuiltin`: lines 312-342
  - `parseDeclSpec`: lines 351-477
- declarators and type names:
  - `parsePointerQualifiers`: lines 479-496
  - `parsePointers`: lines 498-501
  - `parseFunctionParams`: lines 503-531
  - `parseArrayDimensions`: lines 533-539
  - `parseTypeSuffix`: lines 541-549
  - `parseAbstractDeclarator`: lines 551-565
  - `parseTypeName`: lines 567-576
  - `parseDeclarator`: lines 578-608
- aggregates and top-level:
  - `parseStructFields`: lines 610-627
  - `parseStructOrUnion`: lines 629-650
  - `parseEnumSpecifier`: lines 652-682
  - `skipInitializer`: lines 684-687
  - `parseTopLevelDecls`: lines 689-711

### `src/monkeywrench/cparser_nimony.nim`

- integration surface:
  - `NimonyBindingsConfig`: lines 7-16
  - `renderNimonyBindings`: lines 585-607
  - `parseCBindingsToNimony`: lines 609-610
- literal decoding:
  - `parseNumberLiteral`: lines 87-109
  - `parseCharLiteral`: lines 111-154
- expression lowering:
  - `appendBinaryExpr`: lines 162-243
  - `appendExpr`: lines 245-290
- type/declaration lowering:
  - `validateDecl` and `validateType`: lines 294-319
  - `appendEnumField`: lines 328-344
  - `appendField`: lines 346-354
  - `appendParam`: lines 356-372
  - `appendParams`: lines 374-390
  - `appendProcTypeBody`: lines 392-410
  - `appendBuiltinType`: lines 412-429
  - `appendType`: lines 431-474
  - `appendTypeDecl`: lines 476-505
  - `appendStandaloneTaggedType`: lines 507-549
  - `appendProcDecl`: lines 551-571
  - `appendVarDecl`: lines 573-583

## Current supported parser surface

- top-level `typedef`, `extern`, `static`, `inline`, `_Thread_local`
- builtin scalar types
- `struct`, `union`, `enum`
- pointers, arrays, function types, nested declarators
- constant-expression AST nodes for:
  - number literals
  - character literals
  - identifiers
  - unary `+ - ! ~`
  - binary `+ - * / % << >> & | ^ && || == != <= < >= >`
  - cast expressions
  - `sizeof(type)`
  - `sizeof(expr)` parse only
  - `_Alignof(type)` parse only
  - ternary `?:` parse only

## Current supported lowering surface

- top-level type, proc, and global variable declarations
- standalone tagged type declarations
- enum field values through:
  - numbers
  - chars
  - identifiers
  - unary expressions
  - binary expressions
  - casts
  - `sizeof(type)`
- array bounds through the same supported expression subset

## Intentional lowering gaps

These forms already parse but intentionally fail in `appendExpr`:

- `ceConditional`
- `ceSizeofExpr`
- `ceAlignofType`

Reason:

- `nimonyplugins` currently validates `SizeofX` and `AlignofX` as type-only children.
- We do not yet have a validator-safe plugin encoding for `sizeof(expr)`.
- `AlignofX` is still not implemented in Nimony sema.
- Ternary lowering should not be guessed until the correct target form is chosen.

## Concrete next code targets

### 1. `typeof` support in `parseDeclSpec`

Location:

- `src/monkeywrench/cparser.nim:351-477`
- specifically the `of "typeof", "__typeof__":` branch at lines 432-433

Current status:

- `typeof` and `__typeof__` explicitly raise `"typeof is not implemented yet"`.

Expected direction:

- follow chibicc's `typeof_specifier`
- support both expression and type-name forms if practical
- keep the result as a `CType`, not a string fragment

### 2. A real decision for `sizeof(expr)`

Location:

- parser node creation:
  - `src/monkeywrench/cparser.nim:213-220`
- lowerer rejection:
  - `src/monkeywrench/cparser_nimony.nim:282-289`

Current status:

- parser produces `ceSizeofExpr`
- lowerer raises `"sizeof(expr) is not supported in lowering yet"`

Expected direction:

- verify the actual plugin-safe NIF shape first
- do not emit a hand-made shape that passes rendering but fails validation

### 3. `_Alignof(type)` integration

Locations:

- parser:
  - `src/monkeywrench/cparser.nim:221-225`
- lowerer:
  - `src/monkeywrench/cparser_nimony.nim:289-290`

## Test entrypoints

- pure parser regression suite:
  - `tests/tcparser_pure.nim:1-95`
- Nimony integration regression suite:
  - `tests/tcparser_nimony_integration.nim:1-33`

Current status:

- parser produces `ceAlignofType`
- lowerer rejects it because Nimony sema still reports Alignof as unimplemented

## Suggested workflow for the next agent

1. Run the pure parser test first.
2. Run the Nimony integration test second.
3. When changing grammar, compare directly against chibicc's matching function before changing the AST.
4. Keep `cparser_nimony` thin. Parser work should land in the parser, not in lowering-side hacks.

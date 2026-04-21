# Monkeywrench

`monkeywrench` is the extracted work-in-progress repo for the lightweight C parser and Nimony bindings lowering that started inside the Nimony tree.

This repo is intentionally split from the parent compiler sources:

- `src/monkeywrench/` contains the parser, AST, lexer, and NIF lowerer.
- `tests/tcparser_pure.nim` covers the standalone parser without Nimony dependencies.
- `tests/tcparser_nimony_integration.nim` covers lowering through `nimonyplugins`.
- `docs/` contains architecture notes and a detailed porting handoff.
- `plan/` contains the active implementation plan.

## Current dependency boundary

The parser modules are standalone.

The Nimony integration layer is not standalone yet. `src/monkeywrench/cparser_nimony.nim` imports the parent checkout's `src/nimony/lib/nimonyplugins.nim`, so the integration test currently expects this repo to live inside or next to a Nimony checkout. That is deliberate until the lowering API is either stabilized externally or wrapped behind a smaller adapter.

## Verification

Pure parser test:

```sh
nim c --path:src --nimcache:/tmp/monkeywrench-pure -r tests/tcparser_pure.nim
```

Nimony integration test:

```sh
nim c --path:src --nimcache:/tmp/monkeywrench-nimony -r tests/tcparser_nimony_integration.nim
```

## Status

Implemented today:

- top-level declarations, tags, typedef tracking, call conventions
- declarator parsing for pointers, arrays, function types, and nested declarators
- constant-expression AST for numbers, chars, identifiers, unary ops, binary ops, casts, `sizeof(type)`, `_Alignof(type)`, and ternary parse trees
- NIF lowering for declarations plus enum/array constant expressions where the `nimonyplugins` validator already accepts the target shapes

Known intentional gaps:

- `sizeof(expr)` parses but does not lower yet
- `_Alignof(type)` parses but does not lower yet
- ternary expressions parse but do not lower yet
- `typeof` in `declspec` is still unimplemented

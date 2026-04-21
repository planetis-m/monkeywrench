# Architecture

## Modules

- `src/monkeywrench/cparser_ast.nim`
  Defines the lightweight C AST used by the parser and lowerer.
- `src/monkeywrench/cparser_lexer.nim`
  Tokenizes preprocessed C-like input into a small token stream.
- `src/monkeywrench/cparser.nim`
  Parses top-level declarations and declarators with a chibicc-inspired recursive descent.
- `src/monkeywrench/cparser_nimony.nim`
  Lowers the AST to NIF trees through the `nimonyplugins` API.

## Boundaries

### Pure parser boundary

`cparser_ast`, `cparser_lexer`, and `cparser` are independent of Nimony. This is the reusable core for future bindings generation.

### Integration boundary

`cparser_nimony` is currently the only Nimony-dependent module. It should remain a thin lowering layer, not a second parser.

## Design rules for follow-up work

1. Follow chibicc for grammar shape first, especially in expression and declarator parsing.
2. Keep AST additions minimal and structural. Do not reintroduce stringly expression payloads.
3. Only emit NIF shapes that `nimonyplugins` currently validates.
4. If Nimony lacks a valid target encoding, keep the form parseable but reject it clearly during lowering.

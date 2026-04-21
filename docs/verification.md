# Verification

## Commands

Pure parser:

```sh
nim c --path:src --nimcache:/tmp/monkeywrench-pure -r tests/tcparser_pure.nim
```

Nimony integration:

```sh
nim c --path:src --nimcache:/tmp/monkeywrench-nimony -r tests/tcparser_nimony_integration.nim
```

## What these confirm

- lexer, AST, parser, and render helpers work in the isolated repo
- Nimony lowering still works when called from the isolated repo
- the only remaining dependency on the parent Nimony tree is `nimonyplugins`

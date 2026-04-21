# Verification

## Commands

Pure parser:

```sh
nim c --path:src --nimcache:/tmp/monkeywrench-pure -r tests/tcparser_pure.nim
```

Nimony integration:

```sh
bin/nimony c monkeywrench/tests/plugin_compile_ok.nim
```

Negative plugin case:

```sh
bin/nimony c monkeywrench/tests/plugin_compile_error.nim
```

## What these confirm

- lexer, AST, parser, and render helpers work in the isolated repo
- the plugin compiles through the actual Nimony plugin path
- lowering failures return source-level plugin errors instead of crashing the plugin process
- the only remaining dependency on the parent Nimony tree is `nimonyplugins`

# Next Steps

## Immediate

1. Implement `typeof` and `__typeof__` in `parseDeclSpec`, following chibicc's `typeof_specifier` path instead of inventing a different grammar.
2. Decide the correct Nimony-side representation for `sizeof(expr)` and `_Alignof(type)`.
3. Add explicit validation around unsupported lowering forms so plugin failures remain source-level and predictable.

## Parser

1. Extend abstract-declarator coverage with more parameter type-name edge cases.
2. Add tests for additional character literal escapes and reject unsupported multicharacter literals more explicitly.
3. Add more storage/qualifier combinations that mirror chibicc's `declspec` behavior.

## Lowering

1. Replace direct `addIdent` symbol emission for enum expressions with a clearer symbol/reference policy if name resolution requires it.
2. Factor the expression lowering boundary so unsupported AST nodes are reported centrally.
3. Consider a smaller adapter around `nimonyplugins` so this repo no longer imports the parent tree directly.

## Project

1. Add a tiny task runner or CI script for the two test commands in `README.md`.
2. Decide whether `cparser_nimony.nim` stays in this repo or moves to a dedicated integration repo once the parser stabilizes.

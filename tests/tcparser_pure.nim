import monkeywrench/[cparser, cparser_ast, cparser_lexer]

block: # builtin declarations and typedefs
  let decls = parseTopLevelDecls("""
    typedef unsigned long size_t;
    extern int puts(const char *s);
    static int arr[16];
  """)
  doAssert decls.len == 3
  doAssert scTypedef in decls[0].storage
  doAssert decls[0].name == "size_t"
  doAssert decls[0].typ.kind == ctBuiltin
  doAssert decls[0].typ.builtin == btULong
  doAssert scExtern in decls[1].storage
  doAssert decls[1].name == "puts"
  doAssert decls[1].typ.kind == ctFunction
  doAssert decls[1].typ.params.len == 1
  doAssert decls[1].typ.params[0].typ.kind == ctPointer
  doAssert scStatic in decls[2].storage
  doAssert decls[2].name == "arr"
  doAssert decls[2].typ.kind == ctArray

block: # tags and tag references
  let decls = parseTopLevelDecls("""
    struct Foo;
    struct Foo { int x; char *name; };
    typedef struct Foo Foo;
  """)
  doAssert decls.len == 3
  doAssert decls[0].typ.kind == ctStruct
  doAssert decls[0].typ.tagName == "Foo"
  doAssert not decls[0].typ.isComplete
  doAssert decls[1].typ.kind == ctStruct
  doAssert decls[1].typ.isComplete
  doAssert decls[1].typ.fields.len == 2
  doAssert decls[2].name == "Foo"
  doAssert scTypedef in decls[2].storage
  doAssert decls[2].typ.kind == ctStruct

block: # nested declarators
  let decls = parseTopLevelDecls("""
    int (*signal(int sig, void (*func)(int)))(int);
  """)
  doAssert decls.len == 1
  doAssert decls[0].name == "signal"
  doAssert decls[0].typ.kind == ctFunction
  doAssert decls[0].typ.returnType.kind == ctPointer
  doAssert decls[0].typ.returnType.base.kind == ctFunction
  doAssert decls[0].typ.params.len == 2

block: # enums keep raw value expressions
  let decls = parseTopLevelDecls("""
    enum Color { Red, Green = 5, Blue = (1 << 3) };
  """)
  doAssert decls.len == 1
  doAssert decls[0].typ.kind == ctEnum
  doAssert decls[0].typ.items.len == 3
  doAssert decls[0].typ.items[1].valueExpr.kind == ceNumber
  doAssert decls[0].typ.items[1].valueExpr.number == "5"
  doAssert decls[0].typ.items[2].valueExpr.kind == ceBinary
  doAssert decls[0].typ.items[2].valueExpr.binaryOp == "<<"

block: # array bounds keep structured constant expressions
  let decls = parseTopLevelDecls("""
    extern int table[1 << 5];
  """)
  doAssert decls.len == 1
  doAssert decls[0].typ.kind == ctArray
  doAssert decls[0].typ.lenExpr.kind == ceBinary
  doAssert decls[0].typ.lenExpr.binaryOp == "<<"

block: # chibicc-style cast and sizeof(type) expressions parse as structured AST
  let decls = parseTopLevelDecls("""
    enum Bits {
      A = (int) 1U,
      B = sizeof(unsigned long),
      C = 1 ? 2 : 3,
      D = sizeof(int (*)(void))
    };
    extern int buf[sizeof(unsigned short)];
  """)
  doAssert decls.len == 2
  doAssert decls[0].typ.items[0].valueExpr.kind == ceCast
  doAssert decls[0].typ.items[0].valueExpr.targetType.kind == ctBuiltin
  doAssert decls[0].typ.items[1].valueExpr.kind == ceSizeofType
  doAssert decls[0].typ.items[1].valueExpr.typeExpr.kind == ctBuiltin
  doAssert decls[0].typ.items[2].valueExpr.kind == ceConditional
  doAssert decls[0].typ.items[3].valueExpr.kind == ceSizeofType
  doAssert decls[0].typ.items[3].valueExpr.typeExpr.kind == ctPointer
  doAssert decls[0].typ.items[3].valueExpr.typeExpr.base.kind == ctFunction
  doAssert decls[1].typ.lenExpr.kind == ceSizeofType

block: # character literals are valid constant expressions
  let decls = parseTopLevelDecls("""
    enum Letters { A = 'A', NL = '\n', Hex = '\x41' };
  """)
  doAssert decls.len == 1
  doAssert decls[0].typ.items[0].valueExpr.kind == ceChar
  doAssert decls[0].typ.items[0].valueExpr.charLit == "'A'"
  doAssert decls[0].typ.items[1].valueExpr.kind == ceChar
  doAssert decls[0].typ.items[1].valueExpr.charLit == "'\\n'"
  doAssert decls[0].typ.items[2].valueExpr.kind == ceChar
  doAssert decls[0].typ.items[2].valueExpr.charLit == "'\\x41'"

block: # lexer rejects unterminated string and char literals
  doAssertRaises(ValueError):
    discard tokenizeC("\"unterminated")
  doAssertRaises(ValueError):
    discard tokenizeC("'x")

block: # call conventions are preserved
  let decls = parseTopLevelDecls("""
    int __stdcall MessageBoxA(const char *text);
    typedef void (__cdecl *Callback)(int code);
  """)
  doAssert decls.len == 2
  doAssert decls[0].typ.kind == ctFunction
  doAssert decls[0].typ.callConv == ccStdcall
  doAssert decls[1].typ.kind == ctPointer
  doAssert decls[1].typ.base.kind == ctFunction
  doAssert decls[1].typ.base.callConv == ccCdecl

block: # typeof(type-name) works in declaration specifiers
  let decls = parseTopLevelDecls("""
    typedef typeof(unsigned long) size_t2;
    typedef __typeof__(int (*)(void)) CallbackType;
  """)
  doAssert decls.len == 2
  doAssert decls[0].name == "size_t2"
  doAssert decls[0].typ.kind == ctBuiltin
  doAssert decls[0].typ.builtin == btULong
  doAssert decls[1].name == "CallbackType"
  doAssert decls[1].typ.kind == ctPointer
  doAssert decls[1].typ.base.kind == ctFunction

block: # typeof(expr) remains intentionally unsupported
  doAssertRaises(CParseError):
    discard parseTopLevelDecls("""
      typedef typeof(1 + 2) X;
    """)

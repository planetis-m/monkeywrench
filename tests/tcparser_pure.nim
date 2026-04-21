import std/[strutils]
import monkeywrench/[cparser, cparser_ast, cparser_lexer]

block: # builtin declarations and typedefs
  let decls = parseTopLevelDecls("""
    typedef unsigned long size_t;
    extern int puts(const char *s);
    static int arr[16];
  """)
  doAssert decls.len == 3
  doAssert renderDecl(decls[0]) == "typedef unsigned long size_t"
  doAssert renderDecl(decls[1]) == "extern int puts(const char *s)"
  doAssert renderDecl(decls[2]) == "static int arr[16]"

block: # tags and tag references
  let decls = parseTopLevelDecls("""
    struct Foo;
    struct Foo { int x; char *name; };
    typedef struct Foo Foo;
  """)
  doAssert decls.len == 3
  doAssert renderDecl(decls[0]) == "struct Foo"
  doAssert renderDecl(decls[1]) == "struct Foo"
  doAssert renderDecl(decls[2]) == "typedef struct Foo Foo"

block: # nested declarators
  let decls = parseTopLevelDecls("""
    int (*signal(int sig, void (*func)(int)))(int);
  """)
  doAssert decls.len == 1
  doAssert renderDecl(decls[0]) == "int (*signal(int sig, void (*func)(int)))(int)"

block: # enums keep raw value expressions
  let decls = parseTopLevelDecls("""
    enum Color { Red, Green = 5, Blue = (1 << 3) };
  """)
  doAssert decls.len == 1
  doAssert decls[0].typ.kind == ctEnum
  doAssert decls[0].typ.items.len == 3
  doAssert renderExpr(decls[0].typ.items[1].valueExpr) == "5"
  doAssert renderExpr(decls[0].typ.items[2].valueExpr).replace(" ", "") == "(1<<3)"

block: # array bounds keep structured constant expressions
  let decls = parseTopLevelDecls("""
    extern int table[1 << 5];
  """)
  doAssert decls.len == 1
  doAssert decls[0].typ.kind == ctArray
  doAssert renderExpr(decls[0].typ.lenExpr).replace(" ", "") == "(1<<5)"

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
  doAssert renderExpr(decls[0].typ.items[0].valueExpr).replace(" ", "") == "(int)1U"
  doAssert renderExpr(decls[0].typ.items[1].valueExpr).replace(" ", "") ==
    "sizeof(unsignedlong)"
  doAssert renderExpr(decls[0].typ.items[2].valueExpr).replace(" ", "") ==
    "(1?2:3)"
  doAssert renderExpr(decls[0].typ.items[3].valueExpr).replace(" ", "") ==
    "sizeof(int(*)())"
  doAssert renderExpr(decls[1].typ.lenExpr).replace(" ", "") ==
    "sizeof(unsignedshort)"

block: # character literals are valid constant expressions
  let decls = parseTopLevelDecls("""
    enum Letters { A = 'A', NL = '\n', Hex = '\x41' };
  """)
  doAssert decls.len == 1
  doAssert renderExpr(decls[0].typ.items[0].valueExpr) == "'A'"
  doAssert renderExpr(decls[0].typ.items[1].valueExpr) == "'\\n'"
  doAssert renderExpr(decls[0].typ.items[2].valueExpr) == "'\\x41'"

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

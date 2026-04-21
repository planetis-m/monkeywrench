import std/[strutils]
import monkeywrench/[cparser, cparser_nimony]
import ../../src/nimony/lib/nimonyplugins

block:
  let source = """
    typedef unsigned long size_t;
    typedef void (__cdecl *Callback)(int code);
    enum Bits { Casted = (unsigned int) 7, Width = sizeof(unsigned short) };
    enum Letters { A = 'A', NL = '\n' };
    enum Color { Red, Green = 5, Blue };
    struct Foo { int x; char *name; };
    extern int __stdcall puts2(const char *s);
    extern struct Foo currentFoo;
  """
  let decls = parseTopLevelDecls(source)
  let nif = renderTree(renderNimonyBindings(
    decls,
    NimonyBindingsConfig(header: "foo.h", exportSymbols: true)
  ))
  doAssert "(type size_t * ." in nif
  doAssert "(type Callback * ." in nif
  doAssert "(type Bits * ." in nif
  doAssert "(cast" in nif
  doAssert "(sizeof" in nif
  doAssert "(type Letters * ." in nif
  doAssert "(type Color * ." in nif
  doAssert "(proc puts2 * . ." in nif
  doAssert "(stdcall)" in nif
  doAssert "(gvar currentFoo *" in nif

  let nif2 = renderTree(parseCBindingsToNimony(
    source,
    NimonyBindingsConfig(header: "foo.h", exportSymbols: true)
  ))
  doAssert nif2 == nif

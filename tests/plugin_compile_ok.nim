template cBindings(header, spec: string): untyped {.plugin: "../../tests/nimony/plugins/deps/mcbindings".}

cBindings("foo.h", """
  typedef unsigned long size_t;
  typedef void (__cdecl *Callback)(int code);
  enum Bits { Casted = (unsigned int) 7, Width = sizeof(unsigned short) };
  enum Steps { First = 1, Second = First + 1, Third = Second << 1 };
  enum Letters { A = 'A', NL = '\n' };
  enum Color { Red, Green = 5, Blue };
  struct Foo { int x; char *name; };
  extern int __stdcall puts2(const char *s);
  extern int stepsTable[Third];
  extern struct Foo currentFoo;
""")

when isMainModule:
  discard

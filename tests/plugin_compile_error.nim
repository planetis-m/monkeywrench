template cBindings(header, spec: string): untyped {.plugin: "../../tests/nimony/plugins/deps/mcbindings".}

cBindings("foo.h", """
  enum Broken { Bad = sizeof(1 + 2) };
""")

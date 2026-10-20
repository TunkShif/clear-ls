require "../spec_helper"

include ClearLS
include ClearLS::Semantics

private def build(files : Hash(String, String), flags = Set{"linux", "unix"}) : DefMap
  map = DefMap.new(flags)
  parser = Syntax::Parser.new
  files.each_with_index do |(_, src), i|
    map.add_file(FileId.new(i.to_u32), Items::Lower.lower(parser.parse(src)))
  end
  map
end

private def name_of(map, id : TypeId?) : String?
  id.try { |i| map[i].full_name }
end

describe DefMap do
  it "merges reopened types across files" do
    map = build({
      "a.cr" => "class Foo\n  def a; end\nend",
      "b.cr" => "class Foo\n  def b; end\nend\nclass Foo::Bar; end",
    })
    foo = map.lookup_path("Foo").not_nil!
    map[foo].sites.size.should eq 2
    map[foo].members.keys.sort.should eq ["a", "b"]
    map[foo].sites.map(&.file.value).should eq [0, 1]
    name_of(map, map.lookup_path("Foo::Bar")).should eq "Foo::Bar"
  end

  it "resolves paths like the compiler: own types, ancestors, enclosing namespaces" do
    map = build({"a.cr" => <<-CR})
      module Outer
        class Helper; end
        class Base
          class Nested; end
        end
        class Sub < Base
          def x; end
        end
        module Deep
          class Leaf; end
        end
      end
      class Helper; end
      CR
    outer = map.lookup_path("Outer").not_nil!
    sub = map.lookup_path("Outer::Sub").not_nil!
    # Enclosing namespace wins over top-level for the first segment.
    name_of(map, map.lookup_path("Helper", sub)).should eq "Outer::Helper"
    # Ancestor types are visible.
    name_of(map, map.lookup_path("Nested", sub)).should eq "Outer::Base::Nested"
    # Global paths start at the top level.
    name_of(map, map.lookup_path("::Helper", sub)).should eq "Helper"
    # Later segments only search the type and its ancestors.
    map.lookup_path("Outer::Leaf").should be_nil
    name_of(map, map.lookup_path("Deep::Leaf", outer)).should eq "Outer::Deep::Leaf"
    # Self-name resolves to the type itself.
    name_of(map, map.lookup_path("Sub", sub)).should eq "Outer::Sub"
    name_of(map, map.lookup_path("Array(Int32)?", sub)).should be_nil
  end

  it "computes ancestors with includes before superclass" do
    map = build({"a.cr" => <<-CR})
      class Reference; end
      module A; end
      module B; include A; end
      class Base; include B; end
      class Child < Base
        include Comparable
      end
      module Comparable; end
      CR
    child = map.lookup_path("Child").not_nil!
    map.ancestors(child).map { |t| map[t].full_name }.should eq ["Child", "Comparable", "Base", "B", "A", "Reference"]
  end

  it "survives include cycles" do
    map = build({"a.cr" => "module A; include B; end\nmodule B; include A; end"})
    map.ancestors(map.lookup_path("A").not_nil!).size.should eq 2
  end

  it "follows aliases and declares nested paths" do
    map = build({"a.cr" => "module M\n  class Impl; end\n  alias Short = Impl\nend\nclass M::Later; end"})
    name_of(map, map.lookup_path("M::Short")).should eq "M::Impl"
    later = map.lookup_path("M::Later").not_nil!
    map[later].namespace.should eq map.lookup_path("M")
  end

  it "upgrades an implicit namespace when the real declaration arrives" do
    map = build({"a.cr" => "class A::B; end", "b.cr" => "class A; end"})
    map[map.lookup_path("A").not_nil!].kind.should eq TypeKind::Class
  end

  it "filters conditional declarations by target flags" do
    src = "{% if flag?(:win32) %}\nclass Win; end\n{% else %}\nclass Posix; end\n{% end %}"
    linux = build({"a.cr" => src})
    linux.lookup_path("Win").should be_nil
    linux.lookup_path("Posix").should_not be_nil
    win = build({"a.cr" => src}, Set{"win32"})
    win.lookup_path("Win").should_not be_nil
  end

  it "finds members through ancestors and separates class methods" do
    map = build({"a.cr" => "class Base\n  def hi; end\n  def self.make; end\nend\nclass Sub < Base; end"})
    sub = map.lookup_path("Sub").not_nil!
    map.lookup_member(sub, "hi").size.should eq 1
    map.lookup_member(sub, "self.make").size.should eq 1
    map.lookup_member(sub, "make").should be_empty
  end

  it "finds the namespace at an offset" do
    src = "module M\n  class C\n    def x; end\n  end\nend\n"
    map = build({"a.cr" => src})
    map[map.namespace_at(FileId.new(0), src.index!("def x").to_u32)].full_name.should eq "M::C"
    map.namespace_at(FileId.new(0), 0).should eq map.lookup_path("M")
  end
end

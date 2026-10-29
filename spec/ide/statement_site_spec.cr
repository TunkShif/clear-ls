require "../spec_helper"

include ClearLS

# Scope at the word before `‸` in *src* (the marker is removed).
private def site(src : String) : IDE::StatementSite::Scope?
  cur = src.byte_index("‸").not_nil!
  text = src.sub("‸", "")
  offset = cur.to_u32
  start = offset
  while start > 0 && (c = text.byte_at(start - 1).chr) && (c.alphanumeric? || c == '_')
    start -= 1
  end
  IDE::StatementSite.at(text, start, offset)
end

alias Scope = IDE::StatementSite::Scope

describe IDE::StatementSite do
  it "finds statement starts and their scope" do
    site("cla‸").should eq Scope::TopLevel
    site("x = 1\ncla‸\ny = 2\n").should eq Scope::TopLevel
    site("x = 1; cla‸\n").should eq Scope::TopLevel
    site("class A\n  de‸\nend\n").should eq Scope::Type
    site("module M\n  struct S\n    de‸\n  end\nend\n").should eq Scope::Type
    site("enum E\n  A\n  de‸\nend\n").should eq Scope::Enum
    site("lib L\n  fu‸\nend\n").should be_nil # identifiers don't parse in a lib
    site("def f\n  i‸\nend\n").should eq Scope::Def
    site("class A\n  def f\n    xs.each do |x|\n      i‸\n    end\n  end\nend\n").should eq Scope::Def
    site("macro m\n  i‸\nend\n").should be_nil # macro bodies are raw text
    # `begin` is transparent; control flow outside a def is dynamic.
    site("begin\n  de‸\nend\n").should eq Scope::TopLevel
    site("if x\n  cla‸\nend\n").should eq Scope::Dynamic
    site("class A\n  if x\n    de‸\n  end\nend\n").should eq Scope::Dynamic
    site("[1].each do |x|\n  cla‸\nend\n").should eq Scope::Dynamic
    site("while x\n  i‸\nend\n").should eq Scope::Dynamic
  end

  it "is nil off a statement start" do
    site("x = i‸\n").should be_nil
    site("x i‸\n").should be_nil       # argument
    site("foo(a, i‸)\n").should be_nil
    site("return i‸\n").should be_nil
    site("x if i‸\n").should be_nil    # modifier condition
    site("x = 1 i‸\n").should be_nil
    site("cla‸ foo\n").should be_nil   # text after the word
    site("a.cla‸\n").should be_nil
  end

  it "allows a comment after the word" do
    site("de‸ # todo\n").should eq Scope::TopLevel
  end

  it "is nil after a parse error, not after errors past the word" do
    site("class A\n  def f(\n  de‸\nend\n").should be_nil
    site("def f\n  x = [1,\n  i‸\nend\n").should be_nil
    site("class A\n  de‸\nend\nx = [1,\n").should eq Scope::Type
    # A missing `end` turns the whole type into an ERROR: unknown.
    site("class A\n  de‸\n").should be_nil
  end
end

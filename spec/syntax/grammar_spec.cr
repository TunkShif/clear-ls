require "../spec_helper"

describe ClearLS::Syntax::Grammar do
  it "links a compatible grammar" do
    ClearLS::Syntax::Grammar.abi_version.should eq 15
  end

  it "maps every generated kind to a grammar symbol" do
    mapped = (0_u16..0xFFFE_u16).map { |s| ClearLS::Syntax::Grammar.kind(s) }.to_set
    ClearLS::Syntax::Kind.each do |kind|
      next if kind.anonymous? || kind.unknown? || kind.error?
      mapped.should contain(kind)
    end
    ClearLS::Syntax::Grammar.kind(0xFFFF_u16).should eq ClearLS::Syntax::Kind::Error
  end

  it "maps every generated field to a grammar field id" do
    ClearLS::Syntax::Field.each do |field|
      next if field.none?
      id = ClearLS::Syntax::Grammar.field_id(field)
      id.should_not eq 0
      ClearLS::Syntax::Grammar.field(id).should eq field
    end
  end
end

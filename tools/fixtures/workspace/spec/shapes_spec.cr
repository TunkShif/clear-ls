require "./spec_helper"

describe Square do
  it "computes the area" do
    sq = Square.new(3)
    sq.area.should eq 9
  end
end

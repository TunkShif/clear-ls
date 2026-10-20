require "../spec_helper"

include ClearLS

private def lc(line, col)
  LineCol.new(line.to_u32, col.to_u32)
end

describe LineIndex do
  it "indexes line starts" do
    idx = LineIndex.new("ab\ncd\n")
    idx.line_starts.should eq [0, 3, 6]
    idx.line_count.should eq 3
    idx.line_range(0).should eq TextRange.new(0, 2)
    idx.line_range(2).should eq TextRange.new(6, 6)
  end

  it "handles empty text" do
    idx = LineIndex.new("")
    idx.line_count.should eq 1
    idx.point(0).should eq lc(0, 0)
    idx.offset(lc(5, 5), PositionEncoding::UTF16).should eq 0
  end

  it "keeps \\r as line content (CRLF)" do
    idx = LineIndex.new("a\r\nb")
    idx.line_range(0).should eq TextRange.new(0, 2)
    idx.point(4).should eq lc(1, 1)
    idx.position(1, PositionEncoding::UTF16).should eq lc(0, 1)
  end

  # "é" = 2 bytes / 1 utf-16 unit; "中" = 3 / 1; "😀" = 4 / 2.
  text = "aé中😀b\nx"

  it "converts offsets to utf-16 columns" do
    idx = LineIndex.new(text)
    idx.position(0, PositionEncoding::UTF16).should eq lc(0, 0)
    idx.position(1, PositionEncoding::UTF16).should eq lc(0, 1)
    idx.position(3, PositionEncoding::UTF16).should eq lc(0, 2)
    idx.position(6, PositionEncoding::UTF16).should eq lc(0, 3)
    idx.position(10, PositionEncoding::UTF16).should eq lc(0, 5)
    idx.position(11, PositionEncoding::UTF16).should eq lc(0, 6)
    idx.position(12, PositionEncoding::UTF16).should eq lc(1, 0)
  end

  it "converts offsets to utf-32 and utf-8 columns" do
    idx = LineIndex.new(text)
    idx.position(10, PositionEncoding::UTF32).should eq lc(0, 4)
    idx.position(10, PositionEncoding::UTF8).should eq lc(0, 10)
  end

  it "converts utf-16 columns to offsets" do
    idx = LineIndex.new(text)
    idx.offset(lc(0, 3), PositionEncoding::UTF16).should eq 6
    idx.offset(lc(0, 5), PositionEncoding::UTF16).should eq 10
    idx.offset(lc(1, 1), PositionEncoding::UTF16).should eq 13
  end

  it "snaps columns inside a character to its start" do
    idx = LineIndex.new(text)
    # utf-16 column 4 is between the surrogate halves of 😀.
    idx.offset(lc(0, 4), PositionEncoding::UTF16).should eq 6
    # utf-8 column 2 is inside "é".
    idx.offset(lc(0, 2), PositionEncoding::UTF8).should eq 1
    idx.position(2, PositionEncoding::UTF16).should eq lc(0, 1)
  end

  it "clamps past line end and past text end" do
    idx = LineIndex.new(text)
    idx.offset(lc(0, 99), PositionEncoding::UTF16).should eq 11
    idx.offset(lc(9, 0), PositionEncoding::UTF16).should eq text.bytesize
    idx.position(999, PositionEncoding::UTF16).should eq lc(1, 1)
  end

  it "round-trips every character boundary in every encoding" do
    sample = "def ä(x)\r\n  \"中😀\" # ok\n\n  y = '🎉'\nend"
    idx = LineIndex.new(sample)
    boundaries = [0_u32]
    sample.each_char_with_index { |_, i| boundaries << sample.char_index_to_byte_index(i + 1).not_nil!.to_u32 }
    PositionEncoding.each do |enc|
      boundaries.each do |off|
        idx.offset(idx.position(off, enc), enc).should eq off
      end
    end
  end

  it "ignores invalid UTF-8 safely" do
    bad = String.new(Bytes[0x61, 0xFF, 0x62])
    idx = LineIndex.new(bad)
    idx.position(3, PositionEncoding::UTF16).should eq lc(0, 3)
    idx.offset(lc(0, 2), PositionEncoding::UTF16).should eq 2
  end
end

describe "LineIndex random round-trip" do
  it "round-trips random mixed-width text" do
    rng = Random.new(42)
    alphabet = ['a', ' ', '\n', '\r', 'é', '中', '😀', '"']
    200.times do
      sample = String.build { |io| rng.rand(0..40).times { io << alphabet.sample(rng) } }
      idx = ClearLS::LineIndex.new(sample)
      offsets = [0_u32]
      sample.each_char { |c| offsets << offsets.last + c.bytesize }
      ClearLS::PositionEncoding.each do |enc|
        offsets.each { |off| idx.offset(idx.position(off, enc), enc).should eq off }
      end
    end
  end
end

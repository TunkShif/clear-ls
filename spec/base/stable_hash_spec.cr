require "../spec_helper"
require "../../src/clear_ls/base/stable_hash"

describe ClearLS::StableHash do
  it "is XXH64 with seed 0 (vectors from xxhsum -H64)" do
    {
      ""                                        => 0xef46db3751d8e999_u64,
      "a"                                       => 0xd24ec4f1a98c6e5b_u64,
      "abc"                                     => 0x44bc2cf5ad770999_u64,
      "Nobody inspects the spammish repetition" => 0xfbcea83c8a378bf1_u64,
      "x" * 100                                 => 0x92f0de5a88a3c094_u64,
      "q" * 1000                                => 0x53c289a550b16c0f_u64,
    }.each do |text, expected|
      ClearLS::StableHash.hash(text).should eq expected
    end
  end

  it "is the same in another process" do
    # `require` doesn't take absolute paths: run the source itself.
    buf = IO::Memory.new
    src = File.read(File.expand_path("../../src/clear_ls/base/stable_hash.cr", __DIR__))
    src += %(\nprint ClearLS::StableHash.hash("hello"))
    Process.run(ENV["CRYSTAL"]? || "crystal", ["eval", src], output: buf, error: STDERR).success?.should be_true
    buf.to_s.should eq ClearLS::StableHash.hash("hello").to_s
  end
end

require "../spec_helper"
require "file_utils"

include ClearLS

# A fake `crystal` that takes *delay* seconds per command.
private def fake_crystal(dir : String, delay : Float64) : String
  path = File.join(dir, "crystal")
  File.write(path, <<-SH)
    #!/bin/sh
    sleep #{delay}
    case "$1" in
      env) printf 'lib:/opt/crystal/src\\n9.9.9\\n' ;;
      --version) printf 'Crystal 9.9.9\\n\\nDefault target: riscv64-unknown-linux-gnu\\n' ;;
    esac
    SH
  File.chmod(path, 0o755)
  path
end

describe Workspace::Project do
  it "queries the compiler with both commands at once" do
    dir = File.tempname("clear-ls-project")
    Dir.mkdir_p(dir)
    crystal = fake_crystal(dir, 0.3)
    # The first run of a new script can be slow (scanned by an endpoint
    # agent: ~0.4 s on macOS); time the second.
    Workspace::Project.detect(dir, crystal)
    project = nil
    elapsed = Time.measure { project = Workspace::Project.detect(dir, crystal) }
    project = project.not_nil!
    project.crystal_version.should eq "9.9.9"
    project.target_triple.should eq "riscv64-unknown-linux-gnu"
    project.crystal_path.should eq [File.join(dir, "lib"), "/opt/crystal/src"]
    elapsed.should be < 0.55.seconds # one after the other: at least 0.6 s
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "falls back without a compiler" do
    dir = File.tempname("clear-ls-project")
    Dir.mkdir_p(dir)
    project = Workspace::Project.detect(dir, File.join(dir, "no-such-crystal"))
    project.crystal_path.should eq [File.join(dir, "lib")]
    project.crystal_version.should be_nil
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "maps a target triple to its lib_c directory like the compiler" do
    {
      "x86_64-unknown-linux-gnu"   => "x86_64-linux-gnu",
      "x86_64-pc-linux-gnu"        => "x86_64-linux-gnu",
      "x86_64-unknown-linux"       => "x86_64-linux-gnu",
      "aarch64-unknown-linux-musl" => "aarch64-linux-musl",
      "x86_64-alpine-linux-musl"   => "x86_64-linux-musl",
      "aarch64-apple-darwin24.1.0" => "aarch64-darwin",
      "arm64-apple-macosx14.0"     => "aarch64-darwin",
      "x86_64-unknown-freebsd14.1" => "x86_64-freebsd",
      "i686-unknown-linux-gnu"     => "i386-linux-gnu",
      "armv7-unknown-linux-gnueabihf" => "arm-linux-gnueabihf",
      "aarch64-linux-android31"    => "aarch64-android",
      "x86_64-pc-windows-msvc"     => "x86_64-windows-msvc",
      "wasm32-unknown-wasi"        => "wasm32-wasi",
    }.each do |triple, target|
      Workspace::Project.lib_c_target(triple).should eq target
    end
    Workspace::Project.lib_c_target("nonsense").should be_nil
  end

  it "adds the target's lib_c directory to the path once, from the first entry that has it" do
    dir = File.tempname("clear-ls-project")
    std = File.join(dir, "std")
    other = File.join(dir, "other")
    Dir.mkdir_p(File.join(std, "lib_c", "x86_64-linux-gnu", "c"))
    Dir.mkdir_p(File.join(other, "lib_c", "x86_64-linux-gnu"))
    File.write(File.join(std, "lib_c", "x86_64-linux-gnu", "c", "stdint.cr"), "lib LibC\n  alias UInt32T = UInt32\nend\n")
    project = Workspace::Project.new(dir, ["lib", std, other], std, nil, "x86_64-unknown-linux-gnu")
    project.crystal_path.should eq [File.join(dir, "lib"), std, other, File.join(std, "lib_c", "x86_64-linux-gnu")]
    project.resolver.resolve("c/stdint", nil).should eq [File.join(std, "lib_c", "x86_64-linux-gnu", "c", "stdint.cr")]
    # No directory for the target: unchanged.
    Workspace::Project.new(dir, ["lib", std], std, nil, "riscv64-unknown-linux-gnu").crystal_path.should eq [File.join(dir, "lib"), std]
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end

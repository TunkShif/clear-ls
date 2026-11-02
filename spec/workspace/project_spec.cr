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
end

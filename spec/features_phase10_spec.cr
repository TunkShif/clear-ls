require "./spec_helper"
require "./support/feature_client"
require "./support/prelude"

# Many candidate files mentioning `run`, so a references search has many
# checkpoints.
private def jobs_app(n = 40)
  files = {
    "shard.yml"  => "name: app\ntargets:\n  app:\n    main: src/app.cr\n",
    "src/app.cr" => "require \"./parts/*\"\nclass Task\n  def run : Int32\n    1\n  end\nend\nTask.new.run\n",
  }
  n.times { |i| files["src/parts/p#{i}.cr"] = "def caller#{i}(t : Task)\n  t.run\n  t.run\nend\n" }
  files
end

private def refs_params(c)
  {textDocument: {uri: c.uri("src/app.cr")}, position: c.pos("src/app.cr", "def run", 4), context: {includeDeclaration: true}}
end

describe "long requests as jobs" do
  it "answers other requests while a search runs" do
    with_client(jobs_app, PRELUDE_FILES) do |c|
      c.open("src/app.cr")
      rid = c.send_request("textDocument/references", refs_params(c))
      # Dispatched while the job is between checkpoints.
      hover = c.request("textDocument/hover", {textDocument: {uri: c.uri("src/app.cr")}, position: c.pos("src/app.cr", "Task.new", 0)})
      hover["contents"]["value"].as_s.should contain("class Task")
      c.response_of(rid)["result"].as_a.size.should eq 2 + 80
    end
  end

  it "cancels on $/cancelRequest and on edits of files it read" do
    # Enough candidates that the search outlasts the 5 ms sleep below on
    # a fast machine (40 finished first on an M3 Pro).
    with_client(jobs_app(400), PRELUDE_FILES) do |c|
      u = c.open("src/app.cr")
      rid = c.send_request("textDocument/references", refs_params(c))
      c.notify("$/cancelRequest", {id: rid})
      c.response_of(rid)["error"]["code"].should eq ErrorCode::RequestCancelled.value

      rid = c.send_request("textDocument/references", refs_params(c))
      sleep 5.milliseconds # let the job read a few candidates
      c.notify("textDocument/didChange", {textDocument: {uri: u, version: 2}, contentChanges: [{range: {start: {line: 6, character: 0}, end: {line: 6, character: 0}}, text: "# x\n"}]})
      err = c.response_of(rid)["error"]
      err["code"].should eq ErrorCode::ContentModified.value
      err["message"].as_s.should contain("app.cr changed")
      c.server.jobs_running.should eq 0
    end
  end

  it "fails clearly over budget and over the candidate cap" do
    with_client(jobs_app(200), PRELUDE_FILES, budgets: {references: 0.001, maxCandidates: 2000}) do |c|
      c.open("src/app.cr")
      err = c.response_of(c.send_request("textDocument/references", refs_params(c)))["error"]
      err["code"].should eq ErrorCode::RequestFailed.value
      err["message"].as_s.should match(/references stopped after .* s: \d+ of \d+ candidate files searched/)
    end
    with_client(jobs_app(10), PRELUDE_FILES, budgets: {maxCandidates: 5}) do |c|
      c.open("src/app.cr")
      err = c.response_of(c.send_request("textDocument/references", refs_params(c)))["error"]
      err["message"].as_s.should eq "`run` appears in 11 files (limit 5); search not run"
      u = c.uri("src/app.cr")
      err = c.response_of(c.send_request("textDocument/rename", {textDocument: {uri: u}, position: c.pos("src/app.cr", "def run", 4), newName: "go"}))["error"]
      err["message"].as_s.should contain("limit 5")
    end
  end
end

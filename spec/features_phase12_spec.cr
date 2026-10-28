require "./spec_helper"
require "./support/feature_client"
require "./support/prelude"

private def lines_of(refs : JSON::Any, c : FeatureClient) : Array(String)
  refs.as_a.map do |r|
    path = VFS.path_for(r["uri"].as_s).not_nil!.lchop(c.root + "/")
    "#{path}:#{r["range"]["start"]["line"].as_i + 1}:#{r["range"]["start"]["character"].as_i}"
  end.sort
end

private def refs_at(c : FeatureClient, path : String, needle : String, shift = 0) : Array(String)
  u = c.open(path)
  lines_of(c.request("textDocument/references", {textDocument: {uri: u}, position: c.pos(path, needle, shift), context: {includeDeclaration: true}}), c)
end

private def rename_at(c : FeatureClient, path : String, needle : String, shift, new_name : String) : Hash(String, String)
  u = c.open(path)
  edit = c.request("textDocument/rename", {textDocument: {uri: u}, position: c.pos(path, needle, shift), newName: new_name})
  result = {} of String => String
  edit["changes"].as_h.each do |uri, es|
    file = VFS.path_for(uri).not_nil!
    text = File.read(file)
    li = LineIndex.new(text)
    es.as_a.map { |e| {li.offset(LineCol.new(e["range"]["start"]["line"].as_i.to_u32, e["range"]["start"]["character"].as_i.to_u32), PositionEncoding::UTF16),
                       li.offset(LineCol.new(e["range"]["end"]["line"].as_i.to_u32, e["range"]["end"]["character"].as_i.to_u32), PositionEncoding::UTF16), e["newText"].as_s} }
      .sort_by { |(a, _, _)| -a.to_i }.each { |(a, b, t)| text = text.byte_slice(0, a) + t + text.byte_slice(b, text.bytesize - b) }
    result[file.lchop(c.root + "/")] = text
  end
  result
end

describe "accessor references and rename (F1)" do
  files = {
    "shard.yml"  => "name: app\ntargets:\n  app:\n    main: src/app.cr\n",
    "src/app.cr" => <<-CR,
      class Item
        property name = "foo"
        getter? ready = false
        getter! opt : Int32
        class_property count = 0

        def bump
          @name = "x"
          self.name += "y"
          @opt = 1
        end
      end

      record Point, x : Int32, y : Int32

      def go(item : Item, items : Array(Item))
        item.name = "bar"
        items.each &.name = "q"
        puts item.name, item.ready?, item.opt, item.opt?, Item.count
        Item.count = 2
        pt = Point.new(x: 1, y: 2)
        pt.x
      end
      CR
  }

  it "gives one set from the declaration, a getter use, a setter use and the ivar" do
    with_client(files, PRELUDE_FILES) do |c|
      decl = refs_at(c, "src/app.cr", "property name", 9)
      # decl 2, @name 8, self.name += 9, item.name = 17, &.name = 18, item.name 19
      decl.should eq ["src/app.cr:17:7", "src/app.cr:18:14", "src/app.cr:19:12", "src/app.cr:2:11", "src/app.cr:8:4", "src/app.cr:9:9"]
      refs_at(c, "src/app.cr", "puts item.name", 10).should eq decl
      refs_at(c, "src/app.cr", "item.name = ", 5).should eq decl
      refs_at(c, "src/app.cr", "@name = ", 1).should eq decl
      refs_at(c, "src/app.cr", "&.name", 2).should eq decl
    end
  end

  it "groups ? and ! accessors, class accessors and record fields" do
    with_client(files, PRELUDE_FILES) do |c|
      refs_at(c, "src/app.cr", "getter? ready", 8).should eq ["src/app.cr:19:23", "src/app.cr:3:10"]
      refs_at(c, "src/app.cr", "getter! opt", 8).should eq ["src/app.cr:10:4", "src/app.cr:19:36", "src/app.cr:19:46", "src/app.cr:4:10"]
      refs_at(c, "src/app.cr", "class_property count", 15).should eq ["src/app.cr:19:57", "src/app.cr:20:7", "src/app.cr:5:17"]
      # Record field: the getter, the ivar, and the named `new` argument.
      refs_at(c, "src/app.cr", "pt.x", 3).should eq ["src/app.cr:14:14", "src/app.cr:21:17", "src/app.cr:22:5"]
    end
  end

  it "renames every member consistently" do
    with_client(files, PRELUDE_FILES) do |c|
      out = rename_at(c, "src/app.cr", "puts item.name", 10, "title")["src/app.cr"]
      out.should contain %(property title = "foo")
      out.should contain %(@title = "x")
      out.should contain %(self.title += "y")
      out.should contain %(item.title = "bar")
      out.should contain %(&.title = "q")
      out.should contain %(puts item.title,)
      out.should_not contain "name"
      out = rename_at(c, "src/app.cr", "getter? ready", 8, "done")["src/app.cr"]
      out.should contain "getter? done = false"
      out.should contain "item.done?"
    end
  end

  it "hovers the declaration's name with the generated methods" do
    with_client(files, PRELUDE_FILES) do |c|
      u = c.open("src/app.cr")
      h = c.request("textDocument/hover", {textDocument: {uri: u}, position: c.pos("src/app.cr", "property name", 9)})
      md = h["contents"]["value"].as_s
      md.should contain "def Item#name"
      md.should contain "def Item#name=(name)"
      md.should_not contain "local variable"
    end
  end

  it "prepares rename on the base name of any member" do
    with_client(files, PRELUDE_FILES) do |c|
      u = c.open("src/app.cr")
      {"property name" => 9, "item.name =" => 5, "@name = " => 1, "item.ready?" => 5}.each do |needle, shift|
        prep = c.request("textDocument/prepareRename", {textDocument: {uri: u}, position: c.pos("src/app.cr", needle, shift)})
        prep["placeholder"].as_s.should eq(needle.includes?("ready") ? "ready" : "name")
      end
    end
  end

  it "refuses invalid accessor names" do
    with_client(files, PRELUDE_FILES) do |c|
      u = c.open("src/app.cr")
      expect_raises(Exception, /not a valid accessor name/) do
        c.request("textDocument/rename", {textDocument: {uri: u}, position: c.pos("src/app.cr", "property name", 9), newName: "title="})
      end
    end
  end
end

describe "setter and operator completion (F2-2)" do
  files = {
    "src/a.cr" => <<-CR,
      class Item
        property name = "foo"
        def +(other : Item) : Item; self; end
        def [](i : Int32) : Int32; i; end
      end
      item = Item.new
      item.nam
      [item].each &.nam
      item.
      CR
  }

  it "inserts `name = ` for the setter, keeps both visible" do
    c = FeatureClient.new(files, PRELUDE_FILES)
    begin
      u = c.open("src/a.cr")
      r = c.request("textDocument/completion", {textDocument: {uri: u}, position: {line: 6, character: 8}})
      items = r["items"].as_a.to_h { |i| {i["label"].as_s, i} }
      items["name"]["textEdit"]?.should be_nil
      # Optional fields are omitted, never null (Neovim indexes them).
      r["items"].as_a.each { |i| i.as_h.values.none?(&.raw.nil?).should be_true }
      setter = items["name="]
      setter["filterText"].should eq "name"
      setter["textEdit"]["newText"].should eq "name = "
      setter["textEdit"]["range"].should eq JSON.parse(%({"start":{"line":6,"character":5},"end":{"line":6,"character":8}}))
      # `&.name = v` is valid Crystal: same form.
      r = c.request("textDocument/completion", {textDocument: {uri: u}, position: {line: 7, character: 17}})
      r["items"].as_a.find(&.["label"].==("name=")).not_nil!["textEdit"]["newText"].should eq "name = "
    ensure
      c.cleanup
    end
  end

  it "writes binary and index operators in operator form" do
    c = FeatureClient.new(files, PRELUDE_FILES)
    begin
      u = c.open("src/a.cr")
      r = c.request("textDocument/completion", {textDocument: {uri: u}, position: {line: 8, character: 5}})
      items = r["items"].as_a.to_h { |i| {i["label"].as_s, i} }
      plus = items["+"]
      plus["textEdit"]["newText"].should eq " + "
      # Replaces the dot: `item.` → `item + `.
      plus["textEdit"]["range"]["start"].should eq JSON.parse(%({"line":8,"character":4}))
      items["[]"]["textEdit"]["newText"].should eq "[]"
      items["[]"]["insertTextFormat"]?.should be_nil # no snippet support advertised
    ensure
      c.cleanup
    end
  end

  it "keeps method names when setterSnippets is off" do
    c = FeatureClient.new(files, PRELUDE_FILES)
    begin
      c.notify("workspace/didChangeConfiguration", {settings: {clearLs: {completion: {setterSnippets: false}}}})
      u = c.open("src/a.cr")
      r = c.request("textDocument/completion", {textDocument: {uri: u}, position: {line: 6, character: 8}})
      r["items"].as_a.find(&.["label"].==("name=")).not_nil!["textEdit"]?.should be_nil
    ensure
      c.cleanup
    end
  end
end

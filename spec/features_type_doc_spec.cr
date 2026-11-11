require "./support/feature_client"

# A type first opened without a doc (stdlib `File`: `class File <
# IO::FileDescriptor; end` before the requires, documented below) hovers
# with the first reopening's doc, like the compiler's `type.doc ||= ...`.
TYPE_DOC_SRC = <<-CR
  class Base
  end

  class Thing < Base
  end

  # The documented reopening.
  class Thing < Base
    def x; end
  end

  # Second doc, not shown.
  class Thing
  end

  # Documented first.
  class Other
  end

  # Later doc, not shown.
  class Other
  end

  class Bare
  end

  class Bare
  end

  t = Thing
  o = Other
  b = Bare
  CR

private def type_doc_hover(c, path, needle) : String
  h = c.request("textDocument/hover", {textDocument: {uri: c.uri(path)}, position: c.pos(path, needle, 2)})
  h["contents"]["value"].as_s
end

describe "hover on a reopened type" do
  it "takes the doc from the first declaration that has one" do
    c = FeatureClient.new({"src/app.cr" => TYPE_DOC_SRC})
    begin
      c.open("src/app.cr")
      md = type_doc_hover(c, "src/app.cr", "= Thing")
      md.should start_with("```crystal\nclass Thing < Base\n```")
      md.should contain("The documented reopening.")
      md.should_not contain("Second doc")
      md.should contain("_3 declarations_")

      md = type_doc_hover(c, "src/app.cr", "= Other")
      md.should contain("Documented first.")
      md.should_not contain("Later doc")

      md = type_doc_hover(c, "src/app.cr", "= Bare")
      md.should eq "```crystal\nclass Bare\n```\n\n_2 declarations_"
    ensure
      c.cleanup
    end
  end
end

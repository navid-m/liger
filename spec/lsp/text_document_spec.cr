require "../spec_helper"

describe LSP::TextDocument do
  describe "#get_word_at_position" do
    it "extracts word at position" do
      doc = LSP::TextDocument.new(
        "file:///test.cr",
        "crystal",
        1,
        "def hello_world\n  puts \"Hello\"\nend"
      )
      
      # Word "hello_world"
      word = doc.get_word_at_position(LSP::Position.new(0, 5))
      word.should eq("hello_world")
      
      # Word "puts"
      word = doc.get_word_at_position(LSP::Position.new(1, 3))
      word.should eq("puts")
    end

    it "handles positions outside words" do
      doc = LSP::TextDocument.new(
        "file:///test.cr",
        "crystal",
        1,
        "def test\nend"
      )
      
      # Position on whitespace
      word = doc.get_word_at_position(LSP::Position.new(0, 3))
      word.should be_nil
    end

    it "handles Crystal-specific word characters" do
      doc = LSP::TextDocument.new(
        "file:///test.cr",
        "crystal",
        1,
        "empty? nil! @var"
      )
      
      # Method with ?
      word = doc.get_word_at_position(LSP::Position.new(0, 2))
      word.should eq("empty?")
      
      # Method with !
      word = doc.get_word_at_position(LSP::Position.new(0, 8))
      word.should eq("nil!")
    end
  end

  describe "#apply_change" do
    it "applies full document change" do
      doc = LSP::TextDocument.new(
        "file:///test.cr",
        "crystal",
        1,
        "original text"
      )
      
      change = LSP::TextDocumentContentChangeEvent.new("new text")
      doc.apply_change(change)
      
      doc.text.should eq("new text")
    end

    it "applies incremental change" do
      doc = LSP::TextDocument.new(
        "file:///test.cr",
        "crystal",
        1,
        "line 1\nline 2\nline 3"
      )
      
      # Replace "line 2" with "modified"
      range = LSP::Range.new(
        LSP::Position.new(1, 0),
        LSP::Position.new(1, 6)
      )
      change = LSP::TextDocumentContentChangeEvent.new("modified", range)
      doc.apply_change(change)
      
      doc.text.should eq("line 1\nmodified\nline 3")
    end
  end

  describe "#offset_at" do
    it "calculates offset from position" do
      doc = LSP::TextDocument.new(
        "file:///test.cr",
        "crystal",
        1,
        "abc\ndef\nghi"
      )
      
      doc.offset_at(LSP::Position.new(0, 0)).should eq(0)
      doc.offset_at(LSP::Position.new(0, 2)).should eq(2)
      doc.offset_at(LSP::Position.new(1, 0)).should eq(4)
      doc.offset_at(LSP::Position.new(1, 2)).should eq(6)
      doc.offset_at(LSP::Position.new(2, 0)).should eq(8)
    end
  end

  describe "#position_at" do
    it "calculates position from offset" do
      doc = LSP::TextDocument.new(
        "file:///test.cr",
        "crystal",
        1,
        "abc\ndef\nghi"
      )
      
      doc.position_at(0).should eq(LSP::Position.new(0, 0))
      doc.position_at(2).should eq(LSP::Position.new(0, 2))
      doc.position_at(4).should eq(LSP::Position.new(1, 0))
      doc.position_at(6).should eq(LSP::Position.new(1, 2))
      doc.position_at(8).should eq(LSP::Position.new(2, 0))
    end
  end
end

describe LSP::TextDocumentManager do
  it "manages document lifecycle" do
    manager = LSP::TextDocumentManager.new
    
    # Open document
    manager.open("file:///test.cr", "crystal", 1, "initial text")
    doc = manager.get("file:///test.cr")
    doc.should_not be_nil
    doc.not_nil!.text.should eq("initial text")
    
    # Change document
    changes = [LSP::TextDocumentContentChangeEvent.new("updated text")]
    manager.change("file:///test.cr", 2, changes)
    doc = manager.get("file:///test.cr")
    doc.not_nil!.text.should eq("updated text")
    doc.not_nil!.version.should eq(2)
    
    # Close document
    manager.close("file:///test.cr")
    manager.get("file:///test.cr").should be_nil
  end

  it "tracks all open documents" do
    manager = LSP::TextDocumentManager.new
    
    manager.open("file:///test1.cr", "crystal", 1, "text 1")
    manager.open("file:///test2.cr", "crystal", 1, "text 2")
    
    all_docs = manager.all
    all_docs.size.should eq(2)
    all_docs.map(&.uri).should contain("file:///test1.cr")
    all_docs.map(&.uri).should contain("file:///test2.cr")
  end
end

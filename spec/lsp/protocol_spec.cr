require "../spec_helper"

describe LSP::Position do
  describe "#<=>" do
    it "compares positions on the same line" do
      pos1 = LSP::Position.new(1, 5)
      pos2 = LSP::Position.new(1, 10)
      
      (pos1 <=> pos2).should eq(-1)
      (pos2 <=> pos1).should eq(1)
      (pos1 <=> pos1).should eq(0)
    end

    it "compares positions on different lines" do
      pos1 = LSP::Position.new(1, 10)
      pos2 = LSP::Position.new(2, 5)
      
      (pos1 <=> pos2).should eq(-1)
      (pos2 <=> pos1).should eq(1)
    end
  end
end

describe LSP::Range do
  describe "#contains?" do
    it "checks if position is within range" do
      range = LSP::Range.new(
        LSP::Position.new(1, 5),
        LSP::Position.new(1, 10)
      )
      
      range.contains?(LSP::Position.new(1, 7)).should be_true
      range.contains?(LSP::Position.new(1, 5)).should be_true
      range.contains?(LSP::Position.new(1, 10)).should be_true
      range.contains?(LSP::Position.new(1, 3)).should be_false
      range.contains?(LSP::Position.new(1, 15)).should be_false
      range.contains?(LSP::Position.new(0, 7)).should be_false
      range.contains?(LSP::Position.new(2, 7)).should be_false
    end
  end
end

describe LSP::Diagnostic do
  it "creates a diagnostic with required fields" do
    range = LSP::Range.new(
      LSP::Position.new(0, 0),
      LSP::Position.new(0, 5)
    )
    
    diagnostic = LSP::Diagnostic.new(
      range,
      "Test error message",
      LSP::DiagnosticSeverity::Error,
      "test"
    )
    
    diagnostic.range.should eq(range)
    diagnostic.message.should eq("Test error message")
    diagnostic.severity.should eq(LSP::DiagnosticSeverity::Error)
    diagnostic.source.should eq("test")
  end
end

describe LSP::CompletionItem do
  it "creates a completion item" do
    item = LSP::CompletionItem.new(
      "test_method",
      LSP::CompletionItemKind::Method,
      "A test method"
    )
    
    item.label.should eq("test_method")
    item.kind.should eq(LSP::CompletionItemKind::Method)
    item.detail.should eq("A test method")
  end
end

describe LSP::DocumentSymbol do
  it "creates a document symbol" do
    range = LSP::Range.new(
      LSP::Position.new(0, 0),
      LSP::Position.new(10, 0)
    )
    selection_range = LSP::Range.new(
      LSP::Position.new(0, 6),
      LSP::Position.new(0, 15)
    )
    
    symbol = LSP::DocumentSymbol.new(
      "TestClass",
      LSP::SymbolKind::Class,
      range,
      selection_range
    )
    
    symbol.name.should eq("TestClass")
    symbol.kind.should eq(LSP::SymbolKind::Class)
    symbol.range.should eq(range)
    symbol.selection_range.should eq(selection_range)
  end
end

require "./spec_helper"

describe Liger do
  it "has a version number" do
    Liger::VERSION.should_not be_nil
    Liger::VERSION.should eq("0.1.1")
  end
end

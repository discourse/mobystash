require_relative './spec_helper'

require 'mobystash/moby_chunk_parser'

describe Mobystash::MobyChunkParser do
  describe ".new" do
    it "requires tty" do
      expect { described_class.new() {} }.to raise_error(ArgumentError)
    end

    it "requires a block" do
      expect { described_class.new(tty: true) }.to raise_error(ArgumentError)
    end
  end

  describe "#call" do
    let(:result) { [] }

    context "from a TTY container" do
      let(:parser) { described_class.new(tty: true) { |*args| result.replace(args) } }

      it "gives you back what you give it" do
        parser.call("ohai!", 0, 0)
        expect(result).to eq(["ohai!", :tty])
      end
    end

    context "from a multi-stream container" do
      let(:parser) { described_class.new(tty: false) { |*args| result.replace(args) } }

      it "accepts a stdout message" do
        parser.call("\x01\x00\x00\x00\x00\x00\x00\x05ohai!", 0, 0)
        expect(result).to eq(["ohai!", :stdout])
      end

      it "accepts a stderr message" do
        parser.call("\x02\x00\x00\x00\x00\x00\x00\x05ohno!", 0, 0)
        expect(result).to eq(["ohno!", :stderr])
      end

      it "handles a truncated message" do
        parser.call("\x02\x00\x00\x00\x00\x00\x00\x05oh", 0, 0)
        # Nothing yet
        expect(result).to eq([])

        parser.call("no", 0, 0)
        # Wait for it!
        expect(result).to eq([])

        parser.call("!", 0, 0)
        expect(result).to eq(["ohno!", :stderr])
      end

      it "handles a truncated header" do
        parser.call("\x02\x00\x00\x00", 0, 0)
        # Nothing yet
        expect(result).to eq([])

        parser.call("\x00\x00\x00\x05ohno!", 0, 0)
        expect(result).to eq(["ohno!", :stderr])
      end

      it "is unimpressed by an invalid stream ID" do
        expect { parser.call("\x42\x00\x00\x00\x00\x00\x00\x05argh!", 0, 0) }.to raise_error(Mobystash::MobyChunkParser::InvalidChunkError)
      end
    end
  end
end

#!/usr/bin/ruby

require 'json'
require 'nokogiri'

class EntryHandler < Struct.new(:entry)
    def process
        puts 'Processing an Entry!'
    end
end

Nokogiri::XML::Reader(File.open(ARGV[0])).each {
    |node|
    if node.name == 'entry' and node.node_type == Nokogiri::XML::Reader::TYPE_ELEMENT
        ContentHandler.new(
            Nokogiri::XML(node.outer_xml).at('./Content')
        ).process
    end
}

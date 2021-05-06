#!/usr/bin/ruby

require 'json'
require 'nokogiri'

class EntryHandler < Struct.new(:entry_doc)
    def process
        entry = entry_doc #.root
        puts 'Processing an Entry'
        p entry
        title = entry.css('entry title')
        pub = entry.css('entry published')
        upd = entry.css('entry updated')
        p [title.text, pub.text, upd.text]
    end
end

Nokogiri::XML::Reader(File.open(ARGV[0])).each {
    |node|
    if node.name == 'entry' and node.node_type == Nokogiri::XML::Reader::TYPE_ELEMENT
        parsed_node = Nokogiri::XML.parse(node.outer_xml)
        EntryHandler.new(parsed_node).process
    end
}

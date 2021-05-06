#!/usr/bin/ruby

require 'json'
require 'nokogiri'
require 'set'
require 'time'

$all_tags = Set.new()
$all_posts = []

class Post < Struct.new(:post_idx, :title, :pub_ts, :update_ts, :tags, :content)
    def to_json(*args)
        hsh = {}
        hsh['id'] = post_idx
        hsh['title'] = :title
        hsh['featured'] = 0
        hsh['page'] = 0
        hsh['status'] = 'published'
        hsh['published_at'] = (pub_ts.to_f * 1000).to_i
        hsh['published_by'] = 1
        hsh['author_id'] = 1
        hsh['created_at'] = (pub_ts.to_f * 1000).to_i
        hsh['created_by'] = 1
        hsh['updated_at'] = (update_ts.to_f * 1000).to_i
        hsh['updated_by'] = 1

        return hsh.to_json(*args)
    end
end

class EntryHandler < Struct.new(:entry)
    def process()
        # Ignore settings, template, and comments for now.
        kind_cat = entry.at_css('entry category[scheme="http://schemas.google.com/g/2005#kind"]')
        kind = kind_cat['term'].split('#', 2).last
        return unless kind == 'post'

        title = entry.at_css('entry title')
        pub_node = entry.at_css('entry published')
        pub_ts = Time.parse(pub_node.text)
        update_node = entry.at_css('entry updated')
        update_ts = Time.parse(update_node.text)

        tags = entry.css('entry category[scheme="http://www.blogger.com/atom/ns#"]')
        tags = tags.map {|tag_node| tag_node['term']}
        $all_tags << tags
        content = entry.at_css('entry content').text
        content = 'content would go here.'

        new_post_idx = $all_posts.length + 1  # posts are 1-indexed.
        post = Post.new(new_post_idx, title, pub_ts, update_ts, tags, content)

        $all_posts << post unless $all_posts.length >= 5
    end
end

Nokogiri::XML::Reader(File.open(ARGV[0])).each {
    |node|
    if node.name == 'entry' and node.node_type == Nokogiri::XML::Reader::TYPE_ELEMENT
        parsed_node = Nokogiri::XML.parse(node.outer_xml)
        EntryHandler.new(parsed_node).process
    end
}

puts JSON::pretty_generate($all_posts)

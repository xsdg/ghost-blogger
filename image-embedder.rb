#!/usr/bin/ruby

require 'json'
require 'net/http'
require 'uri'

$image_root = File.new('exported_content/downloaded_images')

full_doc = JSON::parse(File.read(ARGV[0]))
all_posts = full_doc['data']['posts']

all_posts.each {
    |post|
    puts "#{post['slug']}:"
    parsed_mobiledoc = JSON.parse(post['mobiledoc'])

    image_dir = File.join($image_root, post['slug'])
    parsed_mobiledoc['cards'].each {
        |(type, card)|
        next unless type == 'image'
        filename = File.basename(card['src'])
        cachename = File.join(image_dir, filename)
        uri = URI(card['src'])

        puts "  #{uri} -> #{cachename}"
    }
    exit
}

#!/usr/bin/ruby

require 'json'

full_doc = JSON::parse(File.read(ARGV[0]))
all_posts = full_doc['data']['posts']

all_posts.each {
    |post|
    parsed_mobiledoc = JSON.parse(post['mobiledoc'])
    p parsed_mobiledoc
    exit
}

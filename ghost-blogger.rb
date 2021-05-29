#!/usr/bin/ruby

require 'json'
require 'nokogiri'
require 'optparse'
require 'set'
require 'time'


# All Ghost timestamps are integer milliseconds.
class Time
    def millis
        return (self.to_f * 1000).to_i
    end
end


# Settings and options parsing.
$settings = (Struct.new(:publish, :verbose, :wrap_html_in_mobiledoc,
                        :process_ranges)).new()
$settings.process_ranges = []

OptionParser.new {
    |opts|
    app_name = File.basename($0)
    opts.banner = "Usage: #{app_name} [options] <blogger_export.xml>"

    opts.on('-pRANGE', '--process=RANGE',
            'Which post indices to process.  Each value should either be a ' +
            'single index, or a ruby-style inclusive or exclusive range.  ' +
            'May be repeated.') {
        |opt|
        if opt =~ /^(-?\d+)$/
            n = $1.to_i
            $settings.process_ranges << Range.new(n, n)
        elsif opt =~ /^(-?\d+)\.\.(-?\d+)$/
            $settings.process_ranges << Range.new($1.to_i, $2.to_i, exclude_end=false)
        elsif opt =~ /^(-?\d+)\.\.\.(-?\d+)$/
            $settings.process_ranges << Range.new($1.to_i, $2.to_i, exclude_end=true)
        else
            raise "Failed to parse --process range \"#{opt}\""
        end
    }

    opts.on('--[no-]publish', 'Whether to mark posts as published or draft') {
        |opt|
        $settings.publish = opt
    }

    opts.on("-v", "--[no-]verbose", "Run verbosely") {
        |opt|
        $settings.verbose = opt
    }

    opts.on('--[no-]wrap_html_in_mobiledoc',
            'If specified, wrap the HTML in a single HTML card in mobiledoc. ' +
            'Otherwise, use the "html" field with the expectation of using ' +
            'Ghost\'s migration tool') {
        |opt|
        $settings.wrap_html_in_mobiledoc = opt
    }
}.parse!


def wrap_content_html_in_mobiledoc(content)
    html_str = content.text
    md = {'version' => '0.3.1', 'markups' => [], 'atoms' => [], 'sections' => [[10, 0]]}
    md['cards'] = [['html', {'cardName' => 'html', 'html' => html_str}]]

    return md
end

class Post < Struct.new(:post_idx, :title, :pub_ts, :update_ts, :slug_tag, :tags, :content, :draft_flag)
    def to_json(*args)
        hsh = {}
        hsh['id'] = post_idx
        hsh['title'] = title.text
        if $settings.wrap_html_in_mobiledoc
            hsh['mobiledoc'] = wrap_content_html_in_mobiledoc(content).to_json
        else
            hsh['html'] = content.text
        end

        if slug_tag
            orig_url = slug_tag['href']
            if orig_url =~ %r{/([^/]+)\.html}
                hsh['slug'] = $1
            else
                $stderr.puts "Failed to parse orig_url: \"#{orig_url}\" for post #{title.text}"
            end
        end

        hsh['featured'] = 0
        hsh['page'] = 0
        hsh['author_id'] = 1
        hsh['created_at'] = pub_ts.millis
        hsh['created_by'] = 1
        hsh['updated_at'] = update_ts.millis
        hsh['updated_by'] = 1

        if draft_flag and draft_flag.text == 'yes'
            hsh['status'] = 'draft'
            if $settings.verbose and $settings.publish
                $stderr.puts "Keeping draft post #{hsh['title']} as a draft even though we're in publish mode"
            end
        elsif $settings.publish
            hsh['status'] = 'published'
            hsh['published_at'] = pub_ts.millis
            hsh['published_by'] = 1
        else
            hsh['status'] = 'draft'
        end

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

        slug_tag = entry.at_css('entry link[rel="alternate"]')
        tags = entry.css('entry category[scheme="http://www.blogger.com/atom/ns#"]')
        tags = tags.map {|tag_node| tag_node['term'].gsub(/^"|"$/, '')}
        content = entry.at_css('entry content')
        draft_flag = entry.at_xpath('.//app:draft', {'app' => 'http://purl.org/atom/app#'})

        new_post_idx = $all_posts.length + 1  # posts are 1-indexed.
        post = Post.new(new_post_idx, title, pub_ts, update_ts, slug_tag, tags, content, draft_flag)

        $all_posts << post
    end
end


# Actually start parsing the input file
$all_posts = []
Nokogiri::XML::Reader(File.open(ARGV[0])).each {
    |node|
    if node.name == 'entry' and node.node_type == Nokogiri::XML::Reader::TYPE_ELEMENT
        parsed_node = Nokogiri::XML.parse(node.outer_xml)
        EntryHandler.new(parsed_node).process
    end
}

# Potentially limits which posts are included.
unless $settings.process_ranges.empty?
    restricted_posts = []
    $settings.process_ranges.each {
        |range|
        restricted_posts += $all_posts[range]
    }
    $all_posts = restricted_posts
end

# Find tags from the possibly-restricted set of posts.
$all_tags = Set.new()
$all_posts.each {
    |post|
    $all_tags |= post.tags
}

# Generate the post-index-to-tag-index mapping.
tag_idx = {}
$all_tags.sort.each_with_index {
    |tag, idx|
    tag_idx[tag] = {'id' => idx, 'name' => tag}
}
posts_tags = []
$all_posts.each {
    |post|
    post['tags'].each {
        |tag|
        pt_pair = {'tag_id' => tag_idx[tag]['id'], 'post_id' => post.post_idx}
        posts_tags << pt_pair
    }
}

# Pack everything up in a box.
$stderr.puts "Processed #{$all_posts.size} posts and #{$all_tags.size} tags"
if $settings.verbose
    $all_posts.each {
        |post|
        $stderr.puts "  #{post.title}"
    }
end

data = {'posts' => $all_posts, 'tags' => tag_idx.values,
        'posts_tags' => posts_tags}
outer = {'meta' => {'exported_on' => Time.now.millis, 'version' => '4.4.0'},
         'data' => data}

puts JSON::pretty_generate(outer)

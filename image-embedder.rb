#!/usr/bin/ruby
# coding: utf-8

require 'fileutils'
require 'json'
require 'net/http'
require 'uri'

image_root_path = 'exported_content/migrated_images'
FileUtils.makedirs(image_root_path)
$image_root = Dir.new(image_root_path)
$settings = {:overwrite_cached_imgs => true, :duplicate_featured_img => true, :year_month_subdirs => true}


def cache_file_locally(uri, local_filename)
    Net::HTTP.start(uri.host) {
        |http|
        if File.exists?(local_filename)
            # Skip downloading if cached file length is as expected.
            local_file_size = File.size(local_filename)

            http.request_head(uri.path) {
                |response|
                canonical_length = response['Content-Length'].to_i
                if local_file_size == canonical_length
                    $stderr.puts "Skipping download of #{uri}; local file is complete"
                    return
                else
                    $stderr.puts "Length mismatch for #{uri}: local file size #{local_file_size} vs canonical #{canonical_length}"
                    if $settings[:overwrite_cached_imgs]
                        $stderr.puts "overwriting local file"
                    else
                        raise "Local image cache collision and overwrites are disabled"
                    end
                end
            }
        end

        # Download and write to local_filename.
        $stderr.print("Fetching #{uri}…")
        $stderr.flush()
        http.request_get(uri.path) {
            |response|
            File.open(local_filename, 'w') {
                |local_file|
                local_file.write(response.body())
            }
        }
        $stderr.puts(" done!")
    }
end


def image_dir_for_post(post)
    built_path = $image_root.dup
    if $settings[:year_month_subdirs]
        post_ts = Time.at(post['created_at'] / 1e3)
        built_path = File.join(built_path, post_ts.strftime('%Y/%m'))
    end
    return File.join(built_path, post['slug'])
end


full_doc = JSON::parse(File.read(ARGV[0]))
all_posts = full_doc['data']['posts']

all_posts.each {
    |post|
    $stderr.puts "#{post['slug']}:"
    parsed_mobiledoc = JSON.parse(post['mobiledoc'])

    feature_idx = nil
    image_dir = image_dir_for_post(post)
    FileUtils.makedirs(image_dir)
    parsed_mobiledoc['cards'].each_with_index {
        |(type, card), card_idx|
        next unless type == 'image'
        filename = File.basename(card['src'])
        cachename = File.join(image_dir, filename)
        uri = URI(card['src'])

        cache_file_locally(uri, cachename)
        # Matches medium_to_ghost/medium_post_parser.py, which notes:
        # TODO: Fix this when Ghost fixes https://github.com/TryGhost/Ghost/issues/9821
        # Ghost 2.0.3 has a bug where it doesn't update imported image paths, so manually add
        # /content/images.
        card['src'] = cachename.sub(/exported_content/, '/content/images')
        card['cardWidth'] = 'wide'  # Non-empty options are "wide" or "full".

        feature_idx ||= card_idx

        $stderr.puts "  #{uri}"
        $stderr.puts "  -> #{cachename}"
        $stderr.puts "  new src #{card['src']}"

        sleep(0.2)
    }

    if feature_idx
        feature_card = (if $settings[:duplicate_featured_image]
                        then parsed_mobiledoc['cards'][feature_idx]
                        else parsed_mobiledoc['cards'].delete_at(feature_idx)
                        end)
        # Matches medium_to_ghost/medium_post_parser.py, which notes:
        # Confusingly, post images ARE updated correctly in 2.0.3, so this path is different
        post['feature_image'] = feature_card.last['src'].sub('exported_content', '')
    end

    post['mobiledoc'] = JSON::generate(parsed_mobiledoc)
}

puts JSON::pretty_generate(full_doc)

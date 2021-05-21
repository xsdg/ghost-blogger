#!/usr/bin/ruby
# coding: utf-8
# The output file _must_ be uploaded after the embedded image zip file.  If it
# is embedded in the zip file, the feature images will not be picked up
# correctly.

require 'fileutils'
require 'json'
require 'net/http'
require 'uri'

image_root_path = 'exported_content/migrated_images'
FileUtils.makedirs(image_root_path)
$image_root = Dir.new(image_root_path)
$settings = Hash.new{|h,k| raise "Unknown settings key #{k}"}
$settings.merge!({:overwrite_cached_imgs => true,
                  :duplicate_featured_image => true,
                  :year_month_subdirs => true})


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
        $stderr.print("  Fetching #{uri}…")
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
    built_path = $image_root
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
        # This differs from medium_to_ghost/medium_post_parser.py in that
        # the __GHOST_URL__ placeholder was introduced, which allows us to use
        # the same image src between normal images and the featured_image.
        card['src'] = cachename.sub(/exported_content/,
                                    '__GHOST_URL__/content/images')
        card['cardWidth'] = 'wide'  # Non-empty options are "wide" or "full".

        feature_idx ||= card_idx

        $stderr.puts "    -> #{cachename}"
        $stderr.puts "    new src #{card['src']}"

        sleep(0.2)
    }

    if feature_idx
        feature_card = (if $settings[:duplicate_featured_image]
                        then parsed_mobiledoc['cards'][feature_idx]
                        else parsed_mobiledoc['cards'].delete_at(feature_idx)
                        end)
        feature_data = feature_card.last
        post['feature_image'] = feature_data['src']
    end

    post['mobiledoc'] = JSON::generate(parsed_mobiledoc)
}

puts JSON::pretty_generate(full_doc)

#!/usr/bin/ruby
# coding: utf-8
# The output file _must_ be uploaded after the embedded image zip file.  If it
# is embedded in the zip file, the feature images will not be picked up
# correctly.

require 'fileutils'
require 'json'
require 'net/http'
require 'optparse'
require 'uri'

# Settings and options parsing.
$settings = (Struct.new(:overwrite_cached_imgs, :duplicate_feature_img,
                        :year_month_subdirs, :image_root_path, :verbose)).new()
# Defaults
$settings.overwrite_cached_imgs = false
$settings.duplicate_feature_img = true
$settings.year_month_subdirs = true
$settings.image_root_path = 'content/migrated_images'

OptionParser.new {
    |opts|
    app_name = File.basename($0)
    opts.banner = "Usage: #{app_name} [options] <ghost-import.json>"

    opts.on('--[no-]duplicate_feature_img',
            'Whether to keep the opening image when setting it as the ' +
            'feature image.  Without customization, this will often lead to ' +
            'the image appearing twice at the start of each post.') {
        |opt|
        $settings.duplicate_feature_img = opt
    }

    opts.on('-oDIR', '--output_dir=DIR', 'Output directory for cached images') {
        |opt|
        $settings.image_root_path = File.join(opt, 'migrated_images')
    }

    opts.on('--[no-]overwrite_cached_imgs',
            'Whether to overwrite mismatching previously-cached images') {
        |opt|
        $settings.overwrite_cached_imgs = opt
    }

    opts.on("-v", "--[no-]verbose", "Run verbosely") {
        |opt|
        $settings.verbose = opt
    }

    opts.on('--[no-]year_month_subdirs',
            'Whether to bucket images by year and month, in addition to post ' +
            'slug.') {
        |opt|
        $settings.year_month_subdirs = opt
    }
}.parse!


FileUtils.makedirs($settings.image_root_path)
$image_root = Dir.new($settings.image_root_path)
def debug(*args)
    if $settings.verbose
        $stderr.puts(*args)
    end
end

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
                    debug "  Skipping download of #{uri}; local file is complete"
                    return
                else
                    size_desc = "local #{local_file_size} versus canonical #{canonical_length}"
                    if $settings.overwrite_cached_imgs
                        debug "    Re-caching #{uri}: #{size_desc}"
                    else
                        raise "Local cache collision and overwrites are disabled: #{size_desc} for #{uri}"
                    end
                end
            }
        end

        # Download and write to local_filename.
        if $settings.verbose
            $stderr.print "  Fetching #{uri}…"
            $stderr.flush()
        end
        http.request_get(uri.path) {
            |response|
            File.open(local_filename, 'w') {
                |local_file|
                local_file.write(response.body())
            }
        }
        debug " done!"
    }
end


def image_dir_for_post(post)
    built_path = $image_root
    if $settings.year_month_subdirs
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
        card['src'] = cachename.sub(/content/,
                                    '__GHOST_URL__/content/images')
        card['cardWidth'] = 'wide'  # Non-empty options are "wide" or "full".

        feature_idx ||= card_idx

        debug "    -> #{cachename}"
        debug "    new src #{card['src']}"

        sleep(0.2)
    }

    if feature_idx
        feature_card = (if $settings.duplicate_feature_img
                        then parsed_mobiledoc['cards'][feature_idx]
                        else parsed_mobiledoc['cards'].delete_at(feature_idx)
                        end)
        feature_data = feature_card.last
        post['feature_image'] = feature_data['src']
    end

    post['mobiledoc'] = JSON::generate(parsed_mobiledoc)
}

puts JSON::pretty_generate(full_doc)

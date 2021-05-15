#!/usr/bin/ruby
# coding: utf-8

require 'fileutils'
require 'json'
require 'net/http'
require 'uri'

image_root_path = 'exported_content/downloaded_images'
FileUtils.makedirs(image_root_path)
$image_root = Dir.new(image_root_path)
$settings = {:overwrite_cached_imgs => true}


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


full_doc = JSON::parse(File.read(ARGV[0]))
all_posts = full_doc['data']['posts']

all_posts.each {
    |post|
    $stderr.puts "#{post['slug']}:"
    parsed_mobiledoc = JSON.parse(post['mobiledoc'])

    image_dir = File.join($image_root, post['slug'])
    FileUtils.makedirs(image_dir)
    parsed_mobiledoc['cards'].each {
        |(type, card)|
        next unless type == 'image'
        filename = File.basename(card['src'])
        cachename = File.join(image_dir, filename)
        uri = URI(card['src'])

        cache_file_locally(uri, cachename)
        card['src'] = cachename.sub(/exported_content/, '/content/images')

        $stderr.puts "  #{uri}"
        $stderr.puts "  -> #{cachename}"
        $stderr.puts "  new src #{card['src']}"

        sleep(0.2)
    }

    post['mobiledoc'] = JSON::generate(parsed_mobiledoc)
}

puts JSON::pretty_generate(full_doc)

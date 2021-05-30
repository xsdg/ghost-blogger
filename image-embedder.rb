#!/usr/bin/ruby
# coding: utf-8
# The output file _must_ be uploaded after the embedded image zip file.  If it
# is embedded in the zip file, the feature images will not be picked up
# correctly.

require 'addressable/uri'
require 'fileutils'
require 'http'
require 'json'
require 'optparse'

# Settings and options parsing.
$settings = (Struct.new(:overwrite_cached_imgs, :duplicate_feature_img,
                        :year_month_subdirs, :image_root_path, :verbose,
                        :skip_cached_imgs, :max_qps, :rewrites,
                        :skip_until)).new()
# Defaults
$settings.max_qps = 4
$settings.duplicate_feature_img = true
$settings.overwrite_cached_imgs = false
$settings.rewrites = {}
$settings.skip_cached_imgs = false
$settings.skip_until = nil
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

    opts.on('-qQPS', '--max_qps=QPS', OptionParser::DecimalNumeric, 'Max per-host QPS limit') {
        |opt|
        $settings.max_qps = opt
    }

    opts.on('-oDIR', '--output_dir=DIR', 'Output directory for cached images') {
        |opt|
        $settings.image_root_path = File.join(opt, 'migrated_images')
    }

    opts.on('--[no-]overwrite_cached_imgs',
            'Whether to overwrite mismatching previously-cached images.  ' +
            'Note that empty local images will be overwritten regardless.') {
        |opt|
        $settings.overwrite_cached_imgs = opt
    }

    opts.on('--rewrite=RULE',
            'Rewrites hosts to other hosts.  Should have format ' +
            '"hostname1 hostname2" to rewrite hostname1 as hostname2 prior ' +
            'to fetching.  May be repeated.') {
        |opt|
        if opt =~ /^(\S+)\s+(\S+)$/
            $settings.rewrites[$1] = $2
        else
            raise "Failed to parse --rewrite rule \"#{opt}\""
        end
    }

    opts.on('--[no-]skip_cached_imgs',
            'Whether to assumed existing images are correct without verifying file size') {
        |opt|
        $settings.skip_cached_imgs = opt
    }

    opts.on('--skip_until=SLUG', String,
            'Do no work until we see SLUG.  This is intended to allow mid-cycle restarts for ' +
            'arbitrary reasons.') {
        |opt|
        $settings.skip_until = opt
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


class LocalFileCacher
    def initialize(max_qps, host_rewrites = {})
        @connections = {}
        @last_requests = Hash.new(Time.at(0))
        @max_qps = max_qps
        @min_request_period = 1.0 / max_qps

        # Hash that returns the specified key as the default value.
        @maybe_rewrite_host = Hash.new {|h,k| k}
        @maybe_rewrite_host.merge!(host_rewrites)
    end

    def start_new_connection(uri)
        # uri.site includes the scheme.
        http = HTTP.persistent(uri.site)
        @connections[uri.hostname] = http
        return http
    end

    def connection_for_uri(uri)
        hostname = @maybe_rewrite_host[uri.hostname]

        if hostname != uri.hostname
            uri = uri.dup  # Avoid modifying the original.
            uri.host = hostname
        end

        unless @connections.has_key? hostname
            return start_new_connection(uri)
        end

        # FIXME: Any way to determine if this connection is still up?
        old_http = @connections[hostname]
        return old_http
    end

    def finish_all()
        @connections.each {
            |hostname, http|
            http.close()
        }
        @connections.clear()
    end

    def sleep_to_limit_qps(uri)
        now = Time.now
        last_request = @last_requests[uri.hostname]
        sleep_duration = (last_request + @min_request_period) - now
        if sleep_duration > 0
            debug "  Sleeping for #{sleep_duration} secs to stay under #{@max_qps} QPS for #{uri.hostname}"
            sleep sleep_duration
        end
        @last_requests[uri.hostname] = Time.now
    end

    # Call like do_request(some_uri, :head)
    # Returns a HTTP::Response.
    def do_request(uri, request_type)
        sleep_to_limit_qps(uri)
        http = connection_for_uri(uri)
        response = http.send(request_type, uri.path)

        # Follow isn't consistent with persistent, since we need to connect to a
        # different host.  So we necessarily start a new connection.
        if response.status.redirect?
            response.flush
            response = HTTP.follow.send(request_type, uri)
        end
        if not response.status.success?
            raise "Failed #{request_type} query on #{uri}: #{response.status}"
        end
        return response
    end

    def should_cache?(uri, local_file_size)
        if local_file_size == 0
            if $settings.skip_cached_imgs or not $settings.overwrite_cached_imgs
                # Higher-priority warning.
                $stderr.puts "    Force-recaching empty local file"
            else
                debug "    Force-recaching empty local file"
            end
            return true
        end

        if $settings.skip_cached_imgs
            debug "  File exists locally; skipping…"
            return false
        end

        response = do_request(uri, :head)
        canonical_length = response.content_length
        response.flush

        if local_file_size == canonical_length
            debug "  Skipping download of #{uri}; local file is complete"
            return false
        else
            size_desc = "local #{local_file_size} versus canonical #{canonical_length}"
            if $settings.overwrite_cached_imgs
                debug "    Re-caching #{uri}: #{size_desc}"
            else
                raise "Local cache collision and overwrites are disabled: #{size_desc} for #{uri}"
            end
        end

        return true
    end

    # Requests the cacher to ensure that a locally-cached version of the file
    # exists.
    #
    # Sleeps long enough to stay under max_qps for each remote server.
    def cache_file_locally(uri, local_filename)
        return if $settings.skip_until

        if File.exists?(local_filename)
            # Skip downloading if cached file length is as expected.
            local_file_size = File.size(local_filename)

            return unless should_cache?(uri, local_file_size)
            if $settings.skip_cached_imgs
                if local_file_size == 0
                    $stderr.puts "    Force-overwriting empty local file"
                else
                    debug "  File exists locally; skipping…"
                    return
                end
            else
                if not should_cache?(uri, local_file_size)
                    return
                end
            end
        end

        # Download and write to local_filename.
        debug "  Fetching #{uri}…"
        img_response = do_request(uri, :get)
        File.open(local_filename, 'w') {
            |local_file|
            local_file.write(img_response.body)
        }
    end
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
cacher = LocalFileCacher.new(max_qps = $settings.max_qps, host_rewrites=$settings.rewrites)

all_posts.each {
    |post|
    $stderr.puts "#{post['slug']}:"

    if $settings.skip_until
        if post['slug'] != $settings.skip_until
            debug "  Skipping image downloads (until slug #{$settings.skip_until})"
        else
            $stderr.puts 'skip_until is satisfied!'
            $settings.skip_until = nil
        end
    end

    parsed_mobiledoc = JSON.parse(post['mobiledoc'])

    feature_idx = nil
    image_dir = image_dir_for_post(post)
    FileUtils.makedirs(image_dir)
    parsed_mobiledoc['cards'].each_with_index {
        |(type, card), card_idx|
        next unless type == 'image'
        filename = Addressable::URI.unencode(File.basename(card['src']))
        cachename = File.join(image_dir, filename)
        uri = Addressable::URI.parse(card['src'])

        cacher.cache_file_locally(uri, cachename)
        # This differs from medium_to_ghost/medium_post_parser.py in that
        # the __GHOST_URL__ placeholder was introduced, which allows us to use
        # the same image src between normal images and the featured_image.
        card['src'] = cachename.sub(/content/,
                                    '__GHOST_URL__/content/images')
        card['cardWidth'] = 'wide'  # Non-empty options are "wide" or "full".

        feature_idx ||= card_idx

        debug "    -> #{cachename}"
        debug "    new src #{card['src']}"
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

cacher.finish_all()
puts JSON::pretty_generate(full_doc)

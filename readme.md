# Ghost Blogger

Simple set of scripts to help migrate blog content from Blogger to Ghost

## Getting Started

### Dependencies

* Ghost migration utils
* ruby-addressable -- URI handling
* ruby-http -- HTTP/S library that's better than Net::HTTP
* ruby-json -- JSON parsing and s
* ruby-nokogiri -- XML and HTML parsing

### Executing program

First and foremost, note that each of the two utilities has lots of options, and
you can see them with `ghost-blogger.rb --help` or `image-embedder.rb --help`.

1) Download blog export from Settings -> Manage Blog -> Back up content
2) Run `ghost-blogger.rb <path_to_blogger_export.xml> > intermediate.json`
   
   `intermediate.json` will (by default) include post content under an `html`
   key for each post.
3) Run `npx migrate json html intermediate.json`
   
   Will produce a file named `ghost-import.json`, with translated post content
   under the `mobiledoc` key for each post.
4) Run `mkdir -p content` to make sure the image download directory exists.
5) Run `image-embedder.rb ghost-import.json > embedded-json-import.json`
   
   Will attempt to cache all post images in the `content` directory, and output
   a version of the import file where all images refer to locally-hosted files
   instead of files on the internet somewhere.
6) Run
   `rm -f embedded-ghost-import.zip; zip -r embedded-ghost-import.zip content/`
   
   Will create an uploadable zip file of all the cached images.  It is
   intentional that this file does *not* contain the json file.
7) Upload `embedded-ghost-import.zip` to Ghost via Settings -> Labs -> Import
   Content.  This will host the files, and will start a background process of
   resizing the files so they can be provided at multiple resolutions.
8) Upload `embedded-ghost-import.json` to Ghost via the same Settings -> Labs
   -> Import Content.  This will import all of the posts.  Note that it's
   important to do this as a separate step -- if you include the JSON in the zip
   file, everything will seem to work, but all of the feature images will be
   broken.

## License

This project is licensed under the Apache License v2.0 - see the LICENSE file for details

## Acknowledgments

* https://github.com/ageitgey/medium_to_ghost
* https://gist.github.com/DomPizzie/7a5ff55ffa9081f2de27c315f5018afc

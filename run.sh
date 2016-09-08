#!/bin/bash
docker run --name blog --rm --volume=$(pwd):/srv/jekyll -it -p 4000:4000 jekyll/jekyll:pages jekyll s --draft

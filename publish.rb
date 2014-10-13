#!/usr/bin/env ruby

tag = `git tag | sort | tail -n 1`.strip
puts "Publishing Ag #{tag}..."

['lucid', 'precise', 'trusty', 'utopic'].each do |release|
    system("rm -rf _build/src")
    system("rm -rf _build/ag_#{tag}*")
    system("mkdir -p _build/src")
    system("git archive #{tag} | gzip -c > _build/src/ag_#{tag}.tar.gz")
    system("cd _build/src && tar xvzf ag_#{tag}.tar.gz")

    File::open('_build/src/debian/changelog', 'w') do |f|
        f.puts "ag (#{tag}~#{release}) #{release}; urgency=low"
        f.puts
        f.puts "  * Initial release"
        f.puts
        f.puts " -- Michael Specht <micha.specht@gmail.com>  Thu,  31 Jul 2014 16:00:00 +0200"
        f.puts
    end

    system("cd _build/src && debuild -S")
    system("dput ppa:micha-specht/ag _build/ag_#{tag}~#{release}_source.changes")
end
